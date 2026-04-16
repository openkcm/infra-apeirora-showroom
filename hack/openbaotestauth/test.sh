CACERT=./ca.crt
CLIENT_CERT=./app2-client2.crt
CLIENT_KEY=./app2-client2.key

TOKEN=$(
  curl --silent --show-error -k \
    --cert "$CLIENT_CERT" \
    --key "$CLIENT_KEY" \
    --request POST \
    https://localhost:62666/v1/auth/cert/login \
  | jq -r '.auth.client_token'
)

echo $TOKEN

curl --silent --show-error -k \
  --cert "$CLIENT_CERT" \
  --key "$CLIENT_KEY" \
  -H "X-Vault-Token: $TOKEN" \
  "https://localhost:62666/v1/kv/data/app1?version=1"
