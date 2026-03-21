listen: :{{PORT}}
tls:
  cert: {{CERT_PATH}}
  key: {{KEY_PATH}}
auth:
  type: password
  password:
    {{CLIENTS}}
masquarade:
  type: proxy
  proxy:
    url: {{MASQUERADE_URL}}
obfs:
  type: {{OBFS_TYPE}}
  {{OBFS_TYPE}}:
    password: {{OBFS_PASSWORD}}
