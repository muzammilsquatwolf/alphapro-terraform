#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["boto3>=1.34"]
# ///
"""
Live status feed for the AlphaPro OMS stack.

Runs on your machine, reads AWS with your own credentials, and serves two
things on one local port:

    /            the Ops Console dashboard (console.html, sitting next to this
                 file) -- same origin as the feed, so no CORS or mixed-content
                 rules apply
    /status      one JSON document describing every ECS service, queue, alarm,
                 target group, cache and database in the stack

Nothing is sent anywhere else. Credentials never leave the machine.

Everything is discovered at runtime from the cluster name prefix, so enabling a
worker or adding a store shows up without editing this file.

The PEP 723 header above means `uv run` installs boto3 into a throwaway
environment for you -- nothing lands in your global site-packages.

    # serve (what the console polls)
    uv run oms_status.py --profile alpha-pro-ap-southeast-1

    # one-shot JSON, no server
    uv run oms_status.py --profile alpha-pro-ap-southeast-1 --once

Read-only: every call is a List*/Describe*/Get*. Nothing here mutates AWS.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CONSOLE = Path(__file__).resolve().with_name("console.html")

try:
    import boto3
    from botocore.config import Config
except ImportError:  # pragma: no cover
    sys.exit(
        "boto3 is not available to this interpreter.\n"
        "Run the script with uv instead, which handles it:\n"
        "    uv run oms_status.py --profile alpha-pro-ap-southeast-1"
    )


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def iso(value):
    """datetime -> ISO-8601 string, passing through anything already serialisable."""
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc).isoformat()
    return value


def chunked(seq, size):
    for i in range(0, len(seq), size):
        yield seq[i:i + size]


def classify(service_name, prefix):
    """Split `alphapro-dev-uae-orders-consumer` into its parts.

    Returns (kind, store, role). kind is one of web / frontend / consumer /
    worker / other; store and role are None for the singleton services.
    """
    rest = service_name[len(prefix):].lstrip("-") if service_name.startswith(prefix) else service_name

    if rest == "web":
        return "web", None, None
    if rest == "frontend":
        return "frontend", None, None

    m = re.match(r"^(?P<store>[^-]+)-(?P<role>[^-]+)-(?P<kind>consumer|worker)$", rest)
    if m:
        return m.group("kind"), m.group("store"), m.group("role")

    return "other", None, None


def queue_parts(queue_name, prefix):
    """`alphapro-dev-uae-orders.fifo` -> ('uae', 'orders', False)."""
    rest = queue_name[len(prefix):].lstrip("-") if queue_name.startswith(prefix) else queue_name
    rest = rest[:-5] if rest.endswith(".fifo") else rest

    is_dlq = rest.endswith("-dlq")
    if is_dlq:
        rest = rest[:-4]

    bits = rest.split("-")
    if len(bits) == 2:
        return bits[0], bits[1], is_dlq
    return None, rest, is_dlq


# --------------------------------------------------------------------------
# collector
# --------------------------------------------------------------------------

class Collector:
    def __init__(self, profile, region, project):
        session_args = {"profile_name": profile} if profile else {}
        self.session = boto3.Session(region_name=region, **session_args)
        self.region = self.session.region_name
        self.project = project
        # Short timeouts keep one unreachable service from stalling the whole poll.
        self.cfg = Config(
            region_name=self.region,
            retries={"max_attempts": 2, "mode": "standard"},
            connect_timeout=4,
            read_timeout=12,
        )
        self._clients = {}
        self._lock = threading.Lock()

    def client(self, name):
        with self._lock:
            if name not in self._clients:
                self._clients[name] = self.session.client(name, config=self.cfg)
            return self._clients[name]

    # -- ECS ---------------------------------------------------------------

    def clusters(self):
        ecs = self.client("ecs")
        arns = []
        for page in ecs.get_paginator("list_clusters").paginate():
            arns += page["clusterArns"]

        wanted = [a for a in arns if a.rsplit("/", 1)[-1].startswith(self.project + "-")]
        if not wanted:
            return []

        out = []
        for batch in chunked(wanted, 100):
            out += ecs.describe_clusters(clusters=batch, include=["STATISTICS"])["clusters"]
        return out

    def cluster_services(self, cluster_arn, prefix):
        ecs = self.client("ecs")

        arns = []
        for page in ecs.get_paginator("list_services").paginate(cluster=cluster_arn):
            arns += page["serviceArns"]
        if not arns:
            return []

        described = []
        for batch in chunked(arns, 10):
            described += ecs.describe_services(cluster=cluster_arn, services=batch)["services"]

        tasks_by_service = self.cluster_tasks(cluster_arn)

        out = []
        for svc in described:
            kind, store, role = classify(svc["serviceName"], prefix)
            primary = next(
                (d for d in svc.get("deployments", []) if d.get("status") == "PRIMARY"),
                None,
            )
            out.append({
                "name": svc["serviceName"],
                "kind": kind,
                "store": store,
                "role": role,
                "status": svc.get("status"),
                "desired": svc.get("desiredCount", 0),
                "running": svc.get("runningCount", 0),
                "pending": svc.get("pendingCount", 0),
                "task_definition": svc.get("taskDefinition", "").rsplit("/", 1)[-1],
                "launch_type": svc.get("launchType")
                               or ", ".join(
                                   s.get("capacityProvider", "")
                                   for s in svc.get("capacityProviderStrategy", [])
                               ),
                "created": iso(svc.get("createdAt")),
                "rollout": (primary or {}).get("rolloutState"),
                "rollout_reason": (primary or {}).get("rolloutStateReason"),
                "deployment_count": len(svc.get("deployments", [])),
                "target_groups": [
                    lb.get("targetGroupArn")
                    for lb in svc.get("loadBalancers", [])
                    if lb.get("targetGroupArn")
                ],
                "events": [
                    {"at": iso(e.get("createdAt")), "message": e.get("message")}
                    for e in svc.get("events", [])[:4]
                ],
                "tasks": tasks_by_service.get(svc["serviceName"], []),
            })
        return out

    def cluster_tasks(self, cluster_arn):
        """One pass over the cluster's tasks, grouped by service name."""
        ecs = self.client("ecs")

        arns = []
        for status in ("RUNNING", "PENDING"):
            for page in ecs.get_paginator("list_tasks").paginate(
                cluster=cluster_arn, desiredStatus=status
            ):
                arns += page["taskArns"]
        if not arns:
            return {}

        tasks = []
        for batch in chunked(arns, 100):
            tasks += ecs.describe_tasks(cluster=cluster_arn, tasks=batch)["tasks"]

        grouped = {}
        for t in tasks:
            group = t.get("group", "")
            if not group.startswith("service:"):
                continue
            service = group.split(":", 1)[1]
            grouped.setdefault(service, []).append({
                "id": t["taskArn"].rsplit("/", 1)[-1][:12],
                "last_status": t.get("lastStatus"),
                "desired_status": t.get("desiredStatus"),
                "health": t.get("healthStatus"),
                "az": t.get("availabilityZone"),
                "cpu": t.get("cpu"),
                "memory": t.get("memory"),
                "started": iso(t.get("startedAt")),
                "stopped_reason": t.get("stoppedReason"),
                "containers": [
                    {
                        "name": c.get("name"),
                        "status": c.get("lastStatus"),
                        "health": c.get("healthStatus"),
                        "exit_code": c.get("exitCode"),
                        "reason": c.get("reason"),
                    }
                    for c in t.get("containers", [])
                ],
            })
        return grouped

    # -- SQS ---------------------------------------------------------------

    def queues(self, prefix):
        sqs = self.client("sqs")

        urls = []
        for page in sqs.get_paginator("list_queues").paginate(QueueNamePrefix=prefix):
            urls += page.get("QueueUrls", [])
        if not urls:
            return []

        def describe(url):
            name = url.rsplit("/", 1)[-1]
            store, qtype, is_dlq = queue_parts(name, prefix)
            try:
                attrs = sqs.get_queue_attributes(
                    QueueUrl=url,
                    AttributeNames=[
                        "ApproximateNumberOfMessages",
                        "ApproximateNumberOfMessagesNotVisible",
                        "ApproximateNumberOfMessagesDelayed",
                        "LastModifiedTimestamp",
                    ],
                )["Attributes"]
            except Exception as exc:  # noqa: BLE001 - surfaced in the payload
                return {"name": name, "store": store, "type": qtype,
                        "dlq": is_dlq, "error": str(exc)}

            return {
                "name": name,
                "store": store,
                "type": qtype,
                "dlq": is_dlq,
                "fifo": name.endswith(".fifo"),
                "visible": int(attrs.get("ApproximateNumberOfMessages", 0)),
                "in_flight": int(attrs.get("ApproximateNumberOfMessagesNotVisible", 0)),
                "delayed": int(attrs.get("ApproximateNumberOfMessagesDelayed", 0)),
            }

        with ThreadPoolExecutor(max_workers=16) as pool:
            return sorted(pool.map(describe, urls), key=lambda q: q["name"])

    # -- CloudWatch --------------------------------------------------------

    def alarms(self, prefix):
        cw = self.client("cloudwatch")
        out = []
        for page in cw.get_paginator("describe_alarms").paginate(AlarmNamePrefix=prefix):
            for a in page.get("MetricAlarms", []):
                out.append({
                    "name": a["AlarmName"],
                    "state": a.get("StateValue"),
                    "reason": a.get("StateReason"),
                    "since": iso(a.get("StateUpdatedTimestamp")),
                    "metric": a.get("MetricName"),
                    "threshold": a.get("Threshold"),
                    "actions_enabled": a.get("ActionsEnabled"),
                    "has_actions": bool(a.get("AlarmActions")),
                })
        return sorted(out, key=lambda a: a["name"])

    # -- ELBv2 -------------------------------------------------------------

    def load_balancers(self, prefix):
        elb = self.client("elbv2")

        lbs = []
        for page in elb.get_paginator("describe_load_balancers").paginate():
            lbs += [lb for lb in page["LoadBalancers"]
                    if lb["LoadBalancerName"].startswith(prefix)]
        if not lbs:
            return []

        out = []
        for lb in lbs:
            arn = lb["LoadBalancerArn"]

            listeners = []
            for page in elb.get_paginator("describe_listeners").paginate(LoadBalancerArn=arn):
                for ls in page["Listeners"]:
                    rules = elb.describe_rules(ListenerArn=ls["ListenerArn"])["Rules"]
                    listeners.append({
                        "port": ls.get("Port"),
                        "protocol": ls.get("Protocol"),
                        "certificates": [c.get("CertificateArn", "").rsplit("/", 1)[-1]
                                         for c in ls.get("Certificates", [])],
                        "default_action": (ls.get("DefaultActions") or [{}])[0].get("Type"),
                        "rules": [
                            {
                                "priority": r.get("Priority"),
                                "action": (r.get("Actions") or [{}])[0].get("Type"),
                                "conditions": [
                                    {"field": c.get("Field"),
                                     "values": c.get("Values")
                                               or (c.get("HostHeaderConfig") or {}).get("Values")
                                               or (c.get("PathPatternConfig") or {}).get("Values")}
                                    for c in r.get("Conditions", [])
                                ],
                            }
                            for r in rules if r.get("Priority") != "default"
                        ],
                    })

            groups = []
            for page in elb.get_paginator("describe_target_groups").paginate(LoadBalancerArn=arn):
                for tg in page["TargetGroups"]:
                    health = elb.describe_target_health(
                        TargetGroupArn=tg["TargetGroupArn"]
                    )["TargetHealthDescriptions"]
                    groups.append({
                        "arn": tg["TargetGroupArn"],
                        "name": tg["TargetGroupName"],
                        "port": tg.get("Port"),
                        "protocol": tg.get("Protocol"),
                        "health_path": tg.get("HealthCheckPath"),
                        "targets": [
                            {
                                "id": t["Target"].get("Id"),
                                "port": t["Target"].get("Port"),
                                "state": t["TargetHealth"].get("State"),
                                "reason": t["TargetHealth"].get("Reason"),
                                "description": t["TargetHealth"].get("Description"),
                            }
                            for t in health
                        ],
                    })

            out.append({
                "name": lb["LoadBalancerName"],
                "dns": lb.get("DNSName"),
                "state": (lb.get("State") or {}).get("Code"),
                "scheme": lb.get("Scheme"),
                "listeners": sorted(listeners, key=lambda l: l["port"] or 0),
                "target_groups": groups,
            })
        return out

    # -- data stores -------------------------------------------------------

    def caches(self, prefix):
        ec = self.client("elasticache")
        out = []
        for page in ec.get_paginator("describe_replication_groups").paginate():
            for g in page["ReplicationGroups"]:
                if not g["ReplicationGroupId"].startswith(prefix):
                    continue
                endpoint = (g.get("NodeGroups") or [{}])[0].get("PrimaryEndpoint") or {}
                out.append({
                    "id": g["ReplicationGroupId"],
                    "status": g.get("Status"),
                    "engine": g.get("Engine"),
                    "version": g.get("CacheNodeType"),
                    "nodes": len(g.get("MemberClusters", [])),
                    "failover": g.get("AutomaticFailover"),
                    "tls": g.get("TransitEncryptionEnabled"),
                    "port": endpoint.get("Port"),
                })
        return sorted(out, key=lambda c: c["id"])

    def databases(self, prefix):
        rds = self.client("rds")
        out = []

        for page in rds.get_paginator("describe_db_clusters").paginate():
            for c in page["DBClusters"]:
                if not c["DBClusterIdentifier"].startswith(prefix):
                    continue
                out.append({
                    "id": c["DBClusterIdentifier"],
                    "kind": "cluster",
                    "status": c.get("Status"),
                    "engine": f"{c.get('Engine')} {c.get('EngineVersion', '')}".strip(),
                    "endpoint": c.get("Endpoint"),
                    "multi_az": c.get("MultiAZ"),
                    "members": len(c.get("DBClusterMembers", [])),
                })

        for page in rds.get_paginator("describe_db_instances").paginate():
            for i in page["DBInstances"]:
                if not i["DBInstanceIdentifier"].startswith(prefix):
                    continue
                if i.get("DBClusterIdentifier"):
                    continue  # already represented by its cluster
                out.append({
                    "id": i["DBInstanceIdentifier"],
                    "kind": "instance",
                    "status": i.get("DBInstanceStatus"),
                    "engine": f"{i.get('Engine')} {i.get('EngineVersion', '')}".strip(),
                    "endpoint": (i.get("Endpoint") or {}).get("Address"),
                    "multi_az": i.get("MultiAZ"),
                    "class": i.get("DBInstanceClass"),
                })
        return sorted(out, key=lambda d: d["id"])

    def nat_addresses(self, prefix):
        ec2 = self.client("ec2")
        out = []
        for page in ec2.get_paginator("describe_nat_gateways").paginate():
            for n in page["NatGateways"]:
                name = next((t["Value"] for t in n.get("Tags", []) if t["Key"] == "Name"), "")
                if not name.startswith(prefix):
                    continue
                out.append({
                    "name": name,
                    "state": n.get("State"),
                    "ips": [a.get("PublicIp") for a in n.get("NatGatewayAddresses", [])],
                })
        return out

    # -- assembly ----------------------------------------------------------

    def collect(self):
        started = time.time()
        payload = {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "region": self.region,
            "project": self.project,
            "environments": [],
            "errors": [],
        }

        try:
            payload["account"] = self.client("sts").get_caller_identity()["Account"]
        except Exception as exc:  # noqa: BLE001
            payload["errors"].append({"scope": "sts", "message": str(exc)})

        try:
            clusters = self.clusters()
        except Exception as exc:  # noqa: BLE001
            payload["errors"].append({"scope": "ecs:clusters", "message": str(exc)})
            payload["duration_ms"] = int((time.time() - started) * 1000)
            return payload

        for cluster in clusters:
            prefix = cluster["clusterName"]              # e.g. alphapro-dev
            env = prefix[len(self.project) + 1:] or prefix

            block = {
                "env": env,
                "cluster": prefix,
                "cluster_status": cluster.get("status"),
                "running_tasks": cluster.get("runningTasksCount"),
                "pending_tasks": cluster.get("pendingTasksCount"),
                "active_services": cluster.get("activeServicesCount"),
                "errors": [],
            }

            jobs = {
                "services": lambda c=cluster, p=prefix: self.cluster_services(c["clusterArn"], p),
                "queues": lambda p=prefix: self.queues(p),
                "alarms": lambda p=prefix: self.alarms(p),
                "load_balancers": lambda p=prefix: self.load_balancers(p),
                "caches": lambda p=prefix: self.caches(p),
                "databases": lambda p=prefix: self.databases(p),
                "nat": lambda p=prefix: self.nat_addresses(p),
            }

            with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
                futures = {key: pool.submit(fn) for key, fn in jobs.items()}
                for key, future in futures.items():
                    try:
                        block[key] = future.result()
                    except Exception as exc:  # noqa: BLE001
                        block[key] = []
                        block["errors"].append({"scope": key, "message": str(exc)})

            payload["environments"].append(block)

        payload["environments"].sort(key=lambda b: b["env"])
        payload["duration_ms"] = int((time.time() - started) * 1000)
        return payload


# --------------------------------------------------------------------------
# server
# --------------------------------------------------------------------------

class Cache:
    """Collapses rapid polls (and several open tabs) onto one AWS round-trip."""

    def __init__(self, collector, ttl):
        self.collector = collector
        self.ttl = ttl
        self.lock = threading.Lock()
        self.at = 0.0
        self.value = None

    def get(self, force=False):
        with self.lock:
            if force or self.value is None or (time.time() - self.at) > self.ttl:
                self.value = self.collector.collect()
                self.at = time.time()
            return self.value


def make_handler(cache):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _cors(self):
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "*")
            # Chrome's Private Network Access check: a public HTTPS page
            # (the console) reaching a loopback server preflights first and
            # needs this header to proceed.
            self.send_header("Access-Control-Allow-Private-Network", "true")
            self.send_header("Access-Control-Max-Age", "600")

        def do_OPTIONS(self):  # noqa: N802
            self.send_response(204)
            self._cors()
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):  # noqa: N802
            path = self.path.split("?", 1)[0]
            content_type = "application/json"

            if path in ("/", "/index.html", "/console.html"):
                # Read per request so editing console.html and reloading the
                # browser is enough — no server restart.
                try:
                    body = CONSOLE.read_bytes()
                    content_type = "text/html; charset=utf-8"
                except OSError:
                    self.send_response(404)
                    self._cors()
                    msg = (f"console.html not found next to {Path(__file__).name}. "
                           f"Expected it at {CONSOLE}.").encode()
                    self.send_header("Content-Type", "text/plain; charset=utf-8")
                    self.send_header("Content-Length", str(len(msg)))
                    self.end_headers()
                    self.wfile.write(msg)
                    return
            elif path == "/health":
                body = json.dumps({"ok": True, "service": "oms-status"}).encode()
            elif path == "/status":
                force = "force=1" in self.path or "refresh=1" in self.path
                try:
                    body = json.dumps(cache.get(force=force), default=str).encode()
                except Exception as exc:  # noqa: BLE001
                    self.send_response(500)
                    self._cors()
                    payload = json.dumps({"error": str(exc)}).encode()
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
            else:
                self.send_response(404)
                self._cors()
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

            self.send_response(200)
            self._cors()
            self.send_header("Content-Type", content_type)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            sys.stderr.write(f"  {self.address_string()} {fmt % args}\n")

    return Handler


def main():
    parser = argparse.ArgumentParser(description="Live status feed for the AlphaPro OMS stack.")
    parser.add_argument("--profile", help="AWS profile (e.g. alpha-pro-ap-southeast-1)")
    parser.add_argument("--region", default="ap-southeast-1")
    parser.add_argument("--project", default="alphapro", help="Cluster name prefix")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--ttl", type=float, default=8.0, help="Seconds to reuse a poll")
    parser.add_argument("--once", action="store_true", help="Print one snapshot and exit")
    args = parser.parse_args()

    collector = Collector(args.profile, args.region, args.project)

    if args.once:
        print(json.dumps(collector.collect(), indent=2, default=str))
        return

    cache = Cache(collector, args.ttl)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(cache))
    server.daemon_threads = True

    print(f"AlphaPro Ops Console  ->  http://{args.host}:{args.port}")
    print(f"  region {collector.region}   project {args.project}   "
          f"profile {args.profile or 'default'}")
    print(f"  raw feed: http://{args.host}:{args.port}/status")
    print("  Open the first URL in a browser. Ctrl-C to stop.\n")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
        server.shutdown()


if __name__ == "__main__":
    main()
