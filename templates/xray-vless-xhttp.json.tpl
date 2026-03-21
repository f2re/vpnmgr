{
  "log": { "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "warning" },
  "inbounds": [
    {
      "port": {{PORT}},
      "protocol": "vless",
      "settings": {
        "clients": [
          {{CLIENTS}}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "{{CERT_PATH}}",
              "keyFile": "{{KEY_PATH}}"
            }
          ]
        },
        "xhttpSettings": { "path": "/{{PATH}}", "mode": "stream" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
