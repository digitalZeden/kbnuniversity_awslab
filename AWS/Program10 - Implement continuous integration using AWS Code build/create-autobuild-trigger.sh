#!/usr/bin/env bash
set -Eeuo pipefail

# Usage:
#   ./create-autobuild-trigger.sh <REPOSITORY_NAME> <CODEBUILD_PROJECT_NAME> [BRANCH[,BRANCH...]] [REGION]
#
# Example:
#   ./create-autobuild-trigger.sh Student002-Repository Student001-CodeBuild master,main eu-north-1
#   (By default, the trigger listens to both master and main.)

REPO_NAME="${1:-}"
BUILD_NAME="${2:-}"
BRANCHES_INPUT="${3:-master,main}"
REGION="${4:-eu-north-1}"

# Accept one branch (master or main) or a comma-separated list (master,main).
IFS=',' read -r -a BRANCHES <<< "$BRANCHES_INPUT"
if [[ ${#BRANCHES[@]} -eq 0 ]]; then
  echo "ERROR: At least one branch must be specified."
  exit 1
fi

# Build the JSON array used by the EventBridge event pattern.
BRANCHES_JSON=""
for branch in "${BRANCHES[@]}"; do
  branch="$(printf '%s' "$branch" | xargs)"
  if [[ -z "$branch" ]]; then
    echo "ERROR: Branch names cannot be empty."
    exit 1
  fi
  if [[ -n "$BRANCHES_JSON" ]]; then
    BRANCHES_JSON+=", "
  fi
  BRANCHES_JSON+="\"${branch}\""
done

if [[ -z "$REPO_NAME" || -z "$BUILD_NAME" ]]; then
  echo "Usage: $0 <REPOSITORY_NAME> <CODEBUILD_PROJECT_NAME> [BRANCH[,BRANCH...]] [REGION]"
  echo "Example: $0 Student002-Repository Student001-CodeBuild master,main eu-north-1"
  echo "Default branches: master,main"
  exit 1
fi

command -v aws >/dev/null 2>&1 || {
  echo "ERROR: AWS CLI is not installed or not in PATH."
  exit 1
}

echo "Checking AWS identity and region..."
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
echo "Account:  ${ACCOUNT_ID}"
echo "Caller:   ${CALLER_ARN}"
echo "Region:   ${REGION}"

echo "Getting CodeCommit repository ARN..."
REPO_ARN="$(aws codecommit get-repository \
  --repository-name "$REPO_NAME" \
  --region "$REGION" \
  --query 'repositoryMetadata.Arn' \
  --output text)"

if [[ -z "$REPO_ARN" || "$REPO_ARN" == "None" ]]; then
  echo "ERROR: Could not find CodeCommit repository '$REPO_NAME' in $REGION."
  exit 1
fi

echo "Getting CodeBuild project ARN..."
PROJECT_ARN="$(aws codebuild batch-get-projects \
  --names "$BUILD_NAME" \
  --region "$REGION" \
  --query 'projects[0].arn' \
  --output text)"

if [[ -z "$PROJECT_ARN" || "$PROJECT_ARN" == "None" ]]; then
  echo "ERROR: Could not find CodeBuild project '$BUILD_NAME' in $REGION."
  exit 1
fi

# Ensure the selected CodeBuild project is connected to the repository supplied.
PROJECT_REPO_URL="$(aws codebuild batch-get-projects \
  --names "$BUILD_NAME" \
  --region "$REGION" \
  --query 'projects[0].source.location' \
  --output text)"
REPO_URL="$(aws codecommit get-repository \
  --repository-name "$REPO_NAME" \
  --region "$REGION" \
  --query 'repositoryMetadata.cloneUrlHttp' \
  --output text)"

if [[ "$PROJECT_REPO_URL" != "$REPO_URL" ]]; then
  echo "ERROR: The CodeBuild project is connected to a different repository."
  echo "Project source: $PROJECT_REPO_URL"
  echo "Requested repo: $REPO_URL"
  echo "Use the repository connected to this CodeBuild project, or update the project source."
  exit 1
fi

# EventBridge rule names are limited to 64 characters.
SAFE_REPO_NAME="$(printf '%s' "$REPO_NAME" | sed 's/[^A-Za-z0-9_-]/-/g')"
RULE_NAME="AutoBuild-${SAFE_REPO_NAME}"
RULE_NAME="${RULE_NAME:0:64}"

ROLE_NAME="EventBridge-CodeBuild-${SAFE_REPO_NAME}"
ROLE_NAME="${ROLE_NAME:0:64}"
POLICY_NAME="AllowStart-${BUILD_NAME}"
POLICY_NAME="${POLICY_NAME:0:128}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/event-pattern.json" <<EOF
{
  "source": ["aws.codecommit"],
  "detail-type": ["CodeCommit Repository State Change"],
  "resources": ["$REPO_ARN"],
  "detail": {
    "event": ["referenceCreated", "referenceUpdated"],
    "referenceType": ["branch"],
    "referenceName": [$BRANCHES_JSON]
  }
}
EOF

cat > "$TMP_DIR/trust-policy.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "events.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

cat > "$TMP_DIR/target-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "codebuild:StartBuild",
      "Resource": "$PROJECT_ARN"
    }
  ]
}
EOF

echo "Creating or updating EventBridge rule: $RULE_NAME"
RULE_ARN="$(aws events put-rule \
  --name "$RULE_NAME" \
  --description "Start CodeBuild when $REPO_NAME branch(es) $BRANCHES_INPUT are updated" \
  --event-pattern "$(cat "$TMP_DIR/event-pattern.json")" \
  --state ENABLED \
  --region "$REGION" \
  --query RuleArn \
  --output text)"

echo "Creating or reusing EventBridge execution role: $ROLE_NAME"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$(cat "$TMP_DIR/trust-policy.json")" \
    --description "Allows EventBridge to start CodeBuild project $BUILD_NAME" \
    >/dev/null
else
  # Keep the trust relationship correct if the role already exists.
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$(cat "$TMP_DIR/trust-policy.json")"
fi

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "$(cat "$TMP_DIR/target-policy.json")"

ROLE_ARN="$(aws iam get-role \
  --role-name "$ROLE_NAME" \
  --query 'Role.Arn' \
  --output text)"

# Allow a newly-created IAM role a short time to propagate.
sleep 10

cat > "$TMP_DIR/targets.json" <<EOF
[
  {
    "Id": "CodeBuildTarget",
    "Arn": "$PROJECT_ARN",
    "RoleArn": "$ROLE_ARN",
    "InputTransformer": {
      "InputPathsMap": {
        "branch": "$.detail.referenceName"
      },
      "InputTemplate": "{\"sourceVersion\": <branch>}"
    }
  }
]
EOF

echo "Attaching CodeBuild project as EventBridge target..."
RESULT="$(aws events put-targets \
  --rule "$RULE_NAME" \
  --targets "$(cat "$TMP_DIR/targets.json")" \
  --region "$REGION")"

FAILED_COUNT="$(printf '%s' "$RESULT" | grep -o '"FailedEntryCount"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*' | head -n 1)"

if [[ -z "$FAILED_COUNT" ]]; then
  echo "ERROR: Could not read FailedEntryCount from EventBridge response:"
  printf '%s\n' "$RESULT"
  exit 1
fi

if [[ "$FAILED_COUNT" != "0" ]]; then
  echo "ERROR: EventBridge reported a failed target entry:"
  printf '%s\n' "$RESULT"
  exit 1
fi

echo
echo "SUCCESS: Automatic CodeBuild trigger configured."
echo "Repository : $REPO_NAME"
echo "Branches   : ${BRANCHES[*]}"
echo "Build      : $BUILD_NAME"
echo "Rule       : $RULE_NAME"
echo "Rule ARN   : $RULE_ARN"
echo
echo "Push a commit to any configured branch (${BRANCHES[*]}) to test the automatic build."
