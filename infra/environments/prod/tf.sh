#!/usr/bin/env bash
# Load this environment's .env as TF_VAR_* and run terraform.
# Usage: ./tf.sh <init|plan|apply|destroy|output|...>
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found in $(pwd)" >&2
  exit 1
fi

# `set -a` exports every variable this file defines — not just TF_VAR_*.
# That's how AWS_PROFILE in .env reaches the AWS SDK without a separate
# export step before every command.
set -a
# shellcheck disable=SC1091
source .env
set +a

# The S3 backend can't read TF_VAR_aws_region directly — backend config is
# resolved before Terraform loads any variables, so `region` can't come from
# .env there. It falls back to the standard AWS SDK region env vars instead,
# which keeps backend.hcl free of a second, easy-to-forget region literal.
export AWS_REGION="$TF_VAR_aws_region"
export AWS_DEFAULT_REGION="$TF_VAR_aws_region"

exec terraform "$@"
