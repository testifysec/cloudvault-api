#!/usr/bin/env bash
# One-shot bootstrap for the CloudVault demo AWS account.
# Run from the management account (profile testifysec-prod) after `aws sso login`.
# Creates: member account, Terraform state bucket, GitHub OIDC provider, CI role.
# Idempotent where AWS lets it be. Tear-down is scripts/demo-account-teardown.sh.
set -euo pipefail

MGMT_PROFILE="${MGMT_PROFILE:-testifysec-prod}"
ACCOUNT_NAME="${ACCOUNT_NAME:-cloudvault-demo}"
ACCOUNT_EMAIL="${ACCOUNT_EMAIL:-aws+cloudvault-demo@testifysec.com}"
REGION="${REGION:-us-east-1}"
GITHUB_REPO="${GITHUB_REPO:-cloudvault-dev/cloudvault-api}"
ROLE_NAME="cloudvault-demo-github-actions"

say() { printf '\n== %s\n' "$*"; }

say "Looking for an existing account named ${ACCOUNT_NAME}"
ACCOUNT_ID="$(aws organizations list-accounts --profile "$MGMT_PROFILE" \
  --query "Accounts[?Name=='${ACCOUNT_NAME}' && Status=='ACTIVE'].Id | [0]" --output text)"

if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
  say "Creating member account ${ACCOUNT_NAME} <${ACCOUNT_EMAIL}>"
  REQ="$(aws organizations create-account --profile "$MGMT_PROFILE" \
    --email "$ACCOUNT_EMAIL" --account-name "$ACCOUNT_NAME" \
    --query 'CreateAccountStatus.Id' --output text)"
  for _ in $(seq 1 40); do
    STATE="$(aws organizations describe-create-account-status --profile "$MGMT_PROFILE" \
      --create-account-request-id "$REQ" --query 'CreateAccountStatus.State' --output text)"
    [[ "$STATE" == "SUCCEEDED" ]] && break
    [[ "$STATE" == "FAILED" ]] && { aws organizations describe-create-account-status --profile "$MGMT_PROFILE" --create-account-request-id "$REQ"; exit 1; }
    sleep 10
  done
  ACCOUNT_ID="$(aws organizations describe-create-account-status --profile "$MGMT_PROFILE" \
    --create-account-request-id "$REQ" --query 'CreateAccountStatus.AccountId' --output text)"
fi
say "Account: ${ACCOUNT_ID}"

say "Assuming OrganizationAccountAccessRole in the new account"
CREDS="$(aws sts assume-role --profile "$MGMT_PROFILE" \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/OrganizationAccountAccessRole" \
  --role-session-name cloudvault-bootstrap --duration-seconds 3600 \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$CREDS"
unset AWS_PROFILE
aws sts get-caller-identity --region "$REGION" --output text

STATE_BUCKET="cloudvault-demo-tfstate-${ACCOUNT_ID}"
say "Terraform state bucket ${STATE_BUCKET}"
if ! aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$REGION" 2>/dev/null; then
  aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION"
  aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$STATE_BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

say "GitHub OIDC provider"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd >/dev/null
fi

say "CI role ${ROLE_NAME} (AdministratorAccess — throwaway demo account)"
TRUST="$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"${OIDC_ARN}"},
 "Action":"sts:AssumeRoleWithWebIdentity","Condition":{
   "StringEquals":{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com"},
   "StringLike":{"token.actions.githubusercontent.com:sub":"repo:${GITHUB_REPO}:*"}}}]}
JSON
)"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null
else
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

say "Wiring the GitHub repo"
gh secret set AWS_GITHUB_ACTIONS_ROLE_ARN -R "$GITHUB_REPO" --body "$ROLE_ARN"
gh variable set TF_STATE_BUCKET -R "$GITHUB_REPO" --body "$STATE_BUCKET"
gh variable set AWS_ACCOUNT_ID -R "$GITHUB_REPO" --body "$ACCOUNT_ID"

say "Done"
echo "ACCOUNT_ID=${ACCOUNT_ID}"
echo "ROLE_ARN=${ROLE_ARN}"
echo "STATE_BUCKET=${STATE_BUCKET}"
