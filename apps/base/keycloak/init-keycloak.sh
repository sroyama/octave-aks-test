#!/usr/bin/env bash

# This script initializes Keycloak by creating the necessary realm, clients, roles and assigning roles to clients.
# For Harmony 3.11, this matches the configuration in https://kidegroup.atlassian.net/wiki/spaces/PD/pages/3998122003/Harmony+IAM+3.11+Client+Configurations

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak:8088}"
ADMIN_USER="${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${KC_BOOTSTRAP_ADMIN_PASSWORD:-change_me}"
KEYCLOAK_WAIT_RETRIES="${WAIT_RETRIES:-30}"
KEYCLOAK_WAIT_SLEEP_TIME="${WAIT_SLEEP_TIME:-5}"

REALM_NAME="${KEYCLOAK_REALM_NAME:-docker-octave-realm}"

# List of clients to create. The values are the client name.
declare -a CLIENTS=(
  "ddss"
  "cdss-ddss"
  "cdss-harmony"
  "jobqueue-ddss"
  "harmony"
  "octave-main"
  "octave-rdb"
  "octave-appdata"
  "octave-fdaparser"
  "octave-shadowgram"
  "octave-pixelsmart"
)

# Build a Dictionary of secrets; each can be overridden via env var:
# ENV name pattern: <CLIENT_ID uppercased, '-' -> '_'>_CLIENT_SECRET
# e.g., cdss-harmony -> CDSS_HARMONY_CLIENT_SECRET
declare -A CLIENT_SECRETS
for client in "${CLIENTS[@]}"; do
  upper="$(echo "$client" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
  env_var="${upper}_CLIENT_SECRET"
  # Default dev secret if env var is not set. Format: "<clientname>-secret"
  default_secret="${client}-secret"
  CLIENT_SECRETS["$client"]="${!env_var:-$default_secret}"
done

# Front-end client configuration
HARMONY_UI_MOCK="octave-harmony-ui-mock"
HARMONY_UI_MOCK_ROOT_URL="${HARMONY_UI_MOCK_ROOT_URL:-http://localhost:4400/}"

# Demo user configuration
DEMO_USERNAME="${DEMO_USERNAME:-demouser}"
DEMO_PASSWORD="${DEMO_PASSWORD:-topcon}"
DEMO_EMAIL="${DEMO_EMAIL:-demouser@example.com}"
DEMO_FIRSTNAME="${DEMO_FIRSTNAME:-Demo}"
DEMO_LASTNAME="${DEMO_LASTNAME:-User}"

# Console log output color definitions
GRAY='\033[90m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
RESET='\033[0m'

wait_for_keycloak() {
  echo -e "${CYAN}Waiting for Keycloak to be be ready...${RESET}"

  # Returns 0 if keycloak is up, 1 if keycloak is not ready
  check_keycloak() {
    response=$(curl -s -o /dev/null -w "%{http_code}" ${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration)
    
    if [ "$response" -eq 200 ]; then
      return 0
    else
      return 1
    fi
  }

  for i in $(seq 1 $KEYCLOAK_WAIT_RETRIES); do
    if check_keycloak; then
      echo -e "${GREEN}Keycloak is up and running.${RESET}"
      return 0
    fi

    echo -e "${YELLOW}Keycloak is not available yet, retrying in $KEYCLOAK_WAIT_SLEEP_TIME seconds. ($i/$KEYCLOAK_WAIT_RETRIES)${RESET}"
    sleep $KEYCLOAK_WAIT_SLEEP_TIME
  done

  echo -e "${RED}Keycloak did not start within the expected time. Exiting.${RESET}"
  exit 1
}

get_admin_token() {
  TOKEN=$(curl -s \
    -d "client_id=admin-cli" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASSWORD}" \
    -d "grant_type=password" \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" | jq -r .access_token)

    if [ "$TOKEN" == "null" ] || [ -z "$TOKEN" ]; then
      echo -e "${RED}Failed to get admin token. Exiting.${RESET}"
      exit 1
    else
      echo -e "${GREEN}Admin token obtained successfully.${RESET}"
    fi
}

check_or_create_realm() {
  echo -e "${CYAN}Checking if realm $REALM_NAME exists.${RESET}"

  REALM_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}")

  if [ "$REALM_RESPONSE" -eq 404 ]; then
    echo -e "${CYAN}  Realm $REALM_NAME does not exist. Creating it.${RESET}"
    curl -s -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"realm\": \"$REALM_NAME\", \"enabled\": true}" \
      "${KEYCLOAK_URL}/admin/realms"
  else
    echo -e "${GRAY}  Realm $REALM_NAME already exists.${RESET}"
  fi
}

check_or_create_client() {
  local client_id=$1
  local client_secret=$2

  echo -e "${CYAN}Checking if client $client_id exists.${RESET}"

  CLIENT=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${client_id}" | jq -r '.[0]')

  if [ "$CLIENT" == "null" ]; then
    echo -e "${CYAN}  Client $client_id does not exist. Creating it.${RESET}"
    curl -s -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"clientId\": \"$client_id\",
        \"secret\": \"$client_secret\",
        \"standardFlowEnabled\": false,
        \"serviceAccountsEnabled\": true,
        \"publicClient\": false,
        \"enabled\": true
      }" "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients"
  else
    echo -e "${GRAY}  Client $client_id already exists.${RESET}"
  fi
}

create_role_for_client() {
  local client_id=$1
  local role_name=$2

  echo -e "${CYAN}Checking if role $role_name exists for client $client_id.${RESET}"

  CLIENT=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${client_id}" | jq -r '.[0].id')
  
  ROLE=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT}/roles/${role_name}" | jq -r '.id')

  if [ "$ROLE" == "null" ]; then
    echo -e "${CYAN}  Role $role_name does not exist. Creating it.${RESET}"
    curl -s -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"$role_name\"}" \
      "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT}/roles"
  else
    echo -e "${GRAY}  Role $role_name already exists.${RESET}"
  fi
}

assign_role_to_service_account() {
  local target_client=$1
  local role_name=$2
  local source_client=$3

  echo -e "${CYAN}Assigning role $role_name to the service account of client $target_client.${RESET}"
  
  TARGET_CLIENT_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${target_client}" | jq -r '.[0].id')
  
  echo "  TARGET_CLIENT_ID: $TARGET_CLIENT_ID"

  SERVICE_ACCOUNT_USER_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${TARGET_CLIENT_ID}/service-account-user" | jq -r '.id')

  echo "  SERVICE_ACCOUNT_USER_ID: $SERVICE_ACCOUNT_USER_ID"

  SOURCE_CLIENT_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${source_client}" | jq -r '.[0].id')
  
  echo "  SOURCE_CLIENT_ID: $SOURCE_CLIENT_ID"

  ROLE_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${SOURCE_CLIENT_ID}/roles/${role_name}" | jq -r '.id')

    echo "  ROLE_ID: $ROLE_ID"

  echo -e "${CYAN}Checking if role $role_name is already assigned to the service account of client $target_client.${RESET}"
  ASSIGNED_ROLES=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/users/${SERVICE_ACCOUNT_USER_ID}/role-mappings/clients/${SOURCE_CLIENT_ID}" | jq -r '.[].name')

  echo "  ASSIGNED_ROLES: $ASSIGNED_ROLES"

  if echo "$ASSIGNED_ROLES" | grep -q "^${role_name}$"; then
    echo -e "${GRAY}  Role $role_name is already assigned to the service account of client $target_client. Skipping.${RESET}"
  else
    echo -e "${CYAN}  Assigning role $role_name to the service account of client $target_client.${RESET}"
    curl -s -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "[{\"id\": \"${ROLE_ID}\", \"name\": \"${role_name}\"}]" \
      "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/users/${SERVICE_ACCOUNT_USER_ID}/role-mappings/clients/${SOURCE_CLIENT_ID}"
    echo -e "${GREEN}  Role $role_name assigned successfully.${RESET}"
  fi
}

check_or_create_frontend_client() {
  local client_id=$1
  local root_url=$2

  echo -e "${CYAN}Checking if client $client_id exists.${RESET}"

  CLIENT=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${client_id}" | jq -r '.[0]')

  if [ "$CLIENT" == "null" ]; then
    echo -e "${CYAN}  Client $client_id does not exist. Creating it.${RESET}"
    curl -s -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"clientId\": \"$client_id\",
        \"rootUrl\": \"$root_url\",
        \"baseUrl\": \"$root_url\",
        \"redirectUris\": [\"${root_url}*\"],
        \"webOrigins\": [\"+\"],
        \"standardFlowEnabled\": true,
        \"directAccessGrantsEnabled\": true,
        \"publicClient\": true,
        \"enabled\": true
      }" "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients"
  else
    echo -e "${GRAY}  Client $client_id already exists.${RESET}"
  fi
}

check_or_create_user() {
  local username=$1
  local password=$2
  local email=$3
  local firstName=$4
  local lastName=$5

  echo -e "${CYAN}Checking if user $username exists in realm $REALM_NAME.${RESET}"

  # Check if the user exists
  USER_COUNT=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/users?username=${username}" | jq -r '. | length')

  if [ "$USER_COUNT" -eq 0 ]; then
    echo -e "${CYAN}  User $username does not exist. Creating it.${RESET}"
    curl -s -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"username\": \"$username\",
        \"email\": \"$email\",
        \"firstName\": \"$firstName\",
        \"lastName\": \"$lastName\",
        \"enabled\": true,
        \"credentials\": [{
          \"type\": \"password\",
          \"value\": \"$password\",
          \"temporary\": false
        }]
      }" \
      "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/users"
    
    echo -e "${GREEN}  User $username created successfully.${RESET}"
  else
    echo -e "${GRAY}  User $username already exists.${RESET}"
  fi
}

check_or_create_client_scope() {
  local scope_name=$1

  echo -e "${CYAN}Checking if client scope $scope_name exists.${RESET}"

  SCOPE_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/client-scopes" | jq -r ".[] | select(.name==\"$scope_name\") | .id")

  if [ -z "$SCOPE_ID" ] || [ "$SCOPE_ID" == "null" ]; then
    echo -e "${CYAN}  Client scope $scope_name does not exist. Creating it.${RESET}"
    curl -s -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"$scope_name\",
        \"protocol\": \"openid-connect\",
        \"attributes\": {
          \"include.in.token.scope\": \"true\",
          \"display.on.consent.screen\": \"false\"
        }
      }" \
      "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/client-scopes"
  else
    echo -e "${GRAY}  Client scope $scope_name already exists.${RESET}"
  fi
}

assign_client_scope_to_client() {
  local client_id_name=$1
  local scope_name=$2
  local scope_type=${3:-default}

  echo -e "${CYAN}Assigning client scope $scope_name as $scope_type to client $client_id_name.${RESET}"

  CLIENT_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${client_id_name}" | jq -r '.[0].id')

  SCOPE_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/client-scopes" | jq -r ".[] | select(.name==\"$scope_name\") | .id")

  if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" == "null" ]; then
    echo "  Client $client_id_name not found. Skipping assignment."
    return
  fi

  if [ -z "$SCOPE_ID" ] || [ "$SCOPE_ID" == "null" ]; then
    echo "  Client scope $scope_name not found. Skipping assignment."
    return
  fi

  if [ "$scope_type" = "optional" ]; then
    # Check if already assigned as optional
    ASSIGNED_SCOPES=$(curl -s -H "Authorization: Bearer $TOKEN" \
      "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_ID}/optional-client-scopes" | jq -r '.[].name')
    if echo "$ASSIGNED_SCOPES" | grep -q "^${scope_name}$"; then
      echo -e "${GRAY}  Client scope $scope_name is already assigned as optional to client $client_id_name. Skipping.${RESET}"
      return
    fi
    echo -e "${CYAN}  Assigning client scope $scope_name as optional to client $client_id_name.${RESET}"
    curl -s -X PUT -H "Authorization: Bearer $TOKEN" \
      "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_ID}/optional-client-scopes/${SCOPE_ID}"
    echo -e "${GREEN}  Client scope $scope_name assigned as optional successfully.${RESET}"
  else
    # Check if already assigned as default
    ASSIGNED_SCOPES=$(curl -s -H "Authorization: Bearer $TOKEN" \
      "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_ID}/default-client-scopes" | jq -r '.[].name')
    if echo "$ASSIGNED_SCOPES" | grep -q "^${scope_name}$"; then
      echo -e "${GRAY}  Client scope $scope_name is already assigned as default to client $client_id_name. Skipping.${RESET}"
      return
    fi
    echo -e "${CYAN}  Assigning client scope $scope_name as default to client $client_id_name.${RESET}"
    curl -s -X PUT -H "Authorization: Bearer $TOKEN" \
      "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_ID}/default-client-scopes/${SCOPE_ID}"
    echo -e "${GREEN}  Client scope $scope_name assigned as default successfully.${RESET}"
  fi
}

add_claim_to_client() {
  local client_id_name=$1
  local mapper_name=$2
  local claim_name=$3
  local claim_value=$4
  local json_type_label=${5:-String}
  local force_update_when_exists=${6:-false}

  echo -e "${CYAN}Ensuring hardcoded claim '$claim_name' exists on client $client_id_name.${RESET}"

  CLIENT_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${client_id_name}" | jq -r '.[0].id')

  if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" == "null" ]; then
    echo "  Client $client_id_name not found. Skipping claim addition."
    return
  fi

  EXISTING_MAPPER=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_ID}/protocol-mappers/models" \
    | jq -c ".[] | select(.name==\"$mapper_name\")")

  if [ -n "$EXISTING_MAPPER" ] && [ "$EXISTING_MAPPER" != "null" ]; then
    MAPPER_ID=$(echo "$EXISTING_MAPPER" | jq -r '.id')
    EXISTING_VALUE=$(echo "$EXISTING_MAPPER" | jq -r '.config["claim.value"]')
    if [ "${force_update_when_exists,,}" = "true" ]; then
      echo -e "${CYAN}  Mapper $mapper_name exists (force update enabled). Updating value from '$EXISTING_VALUE' to '$claim_value'.${RESET}"
      curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        -d "{
          \"id\": \"$MAPPER_ID\",
          \"name\": \"$mapper_name\",
          \"protocol\": \"openid-connect\",
          \"protocolMapper\": \"oidc-hardcoded-claim-mapper\",
          \"consentRequired\": false,
          \"config\": {
            \"claim.name\": \"$claim_name\",
            \"claim.value\": \"$claim_value\",
            \"id.token.claim\": \"true\",
            \"access.token.claim\": \"true\",
            \"userinfo.token.claim\": \"true\",
            \"jsonType.label\": \"$json_type_label\"
          }
        }" \
        "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_ID}/protocol-mappers/models/${MAPPER_ID}" >/dev/null
    else
      if [ "$EXISTING_VALUE" != "$claim_value" ]; then
        echo -e "${GRAY}  Mapper $mapper_name already exists with value '$EXISTING_VALUE'. Skipping update (forceUpdateWhenExists=false).${RESET}"
      else
        echo -e "${GRAY}  Mapper $mapper_name already exists with identical value. No update needed.${RESET}"
      fi
    fi
  else
    echo -e "${CYAN}  Mapper $mapper_name not found. Creating it.${RESET}"
    curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "{
        \"name\": \"$mapper_name\",
        \"protocol\": \"openid-connect\",
        \"protocolMapper\": \"oidc-hardcoded-claim-mapper\",
        \"consentRequired\": false,
        \"config\": {
          \"claim.name\": \"$claim_name\",
          \"claim.value\": \"$claim_value\",
          \"id.token.claim\": \"true\",
          \"access.token.claim\": \"true\",
          \"userinfo.token.claim\": \"true\",
          \"jsonType.label\": \"$json_type_label\"
        }
      }" \
      "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_ID}/protocol-mappers/models" >/dev/null
  fi
}

wait_for_keycloak

get_admin_token

check_or_create_realm

# Create the demo user
check_or_create_user "$DEMO_USERNAME" "$DEMO_PASSWORD" "$DEMO_EMAIL" "$DEMO_FIRSTNAME" "$DEMO_LASTNAME"

# Create all service clients from enum using the Dictionary of secrets
for client in "${CLIENTS[@]}"; do
  check_or_create_client "$client" "${CLIENT_SECRETS[$client]}"
done

# Client scope setup
check_or_create_client_scope "harmony:access"
check_or_create_client_scope "harmony:access:read"
check_or_create_client_scope "harmony:access:write"

check_or_create_client_scope "ddss:data:read"
check_or_create_client_scope "ddss:data:write"
check_or_create_client_scope "ddss:data:admin"

check_or_create_client_scope "ddss:schema:owner"
check_or_create_client_scope "ddss:schema:read"
check_or_create_client_scope "ddss:schema:admin"

check_or_create_client_scope "octave:rdb:read"

check_or_create_client_scope "octave:appdata:read"
check_or_create_client_scope "octave:appdata:write"
check_or_create_client_scope "octave:appdata:admin"

check_or_create_client_scope "octave:fdaparser:write"
check_or_create_client_scope "octave:pixelsmart:write"
check_or_create_client_scope "octave:shadowgram:write"

# Assign client scopes to clients
assign_client_scope_to_client "octave-main"  "harmony:access" "default"
assign_client_scope_to_client "cdss-harmony" "harmony:access" "optional"

assign_client_scope_to_client "octave-main"  "harmony:access:read" "optional"
assign_client_scope_to_client "cdss-harmony" "harmony:access:read" "optional"

assign_client_scope_to_client "cdss-harmony" "harmony:access:write" "optional"

assign_client_scope_to_client "cdss-ddss"         "ddss:data:read" "default"
assign_client_scope_to_client "ddss"              "ddss:data:read" "optional"
assign_client_scope_to_client "octave-main"       "ddss:data:read" "optional"
assign_client_scope_to_client "octave-fdaparser"  "ddss:data:read" "optional"
assign_client_scope_to_client "octave-pixelsmart" "ddss:data:read" "optional"
assign_client_scope_to_client "octave-shadowgram" "ddss:data:read" "optional"

assign_client_scope_to_client "jobqueue-ddss"     "ddss:data:write" "default"
assign_client_scope_to_client "ddss"              "ddss:data:write" "optional"
assign_client_scope_to_client "octave-fdaparser" "ddss:data:write" "optional"

assign_client_scope_to_client "ddss" "ddss:data:admin" "optional"

assign_client_scope_to_client "jobqueue-ddss"    "ddss:schema:owner" "default"
assign_client_scope_to_client "ddss"             "ddss:schema:owner" "optional"
assign_client_scope_to_client "octave-fdaparser" "ddss:schema:owner" "optional"

assign_client_scope_to_client "ddss" "ddss:schema:read" "optional"
assign_client_scope_to_client "ddss" "ddss:schema:admin" "optional"

assign_client_scope_to_client "octave-main" "octave:rdb:read"      "default"
assign_client_scope_to_client "octave-main" "octave:appdata:read"  "default"
assign_client_scope_to_client "octave-main" "octave:appdata:write" "default"

assign_client_scope_to_client "octave-main" "octave:appdata:admin" "optional"

assign_client_scope_to_client "jobqueue-ddss" "octave:shadowgram:write" "optional"
assign_client_scope_to_client "jobqueue-ddss" "octave:fdaparser:write"  "optional"
assign_client_scope_to_client "jobqueue-ddss" "octave:pixelsmart:write" "optional"

# Create the frontend client (public)
check_or_create_frontend_client "$HARMONY_UI_MOCK" "$HARMONY_UI_MOCK_ROOT_URL"

# Add "octave" boolean claim to the frontend client
add_claim_to_client "$HARMONY_UI_MOCK" "octave-claim" "octave" "true" "boolean"

echo -e "${GREEN}Keycloak initialization complete.${RESET}"
