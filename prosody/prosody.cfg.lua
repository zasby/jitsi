admins = {}

modules_enabled = {
  "websocket";
  "bosh";
  "ping";
  "roster";
  "pep";
  "private";
  "blocklist";
  "vcard4";
  "vcard_legacy";
  "limits";
  "csi_simple";
  "mam";
  "http";
}

modules_disabled = {
  "posix";
}

http_ports = { 5280 }
https_ports = { }
http_interfaces = { "*" }

-- Явное сопоставление путей модулей
http_paths = {
  bosh = "/http-bind";
  websocket = "/xmpp-websocket";
}

cross_domain_websocket = true
consider_bosh_secure = true

-- Отключаем требование TLS глобально
c2s_require_encryption = false
s2s_require_encryption = false

VirtualHost "connect.mooz.pro"
  authentication = "anonymous"
  allow_unencrypted_plain_auth = true
  ssl = { }
  modules_enabled = {
    "websocket"; "bosh"; "ping"; "mam";
  }
  -- Отключаем требование TLS для внутренних соединений
  c2s_require_encryption = false
  s2s_require_encryption = false

VirtualHost "auth.connect.mooz.pro"
  authentication = "internal_hashed"

Component "conference.connect.mooz.pro" "muc"
  restrict_room_creation = false
  max_history_messages = 0
  muc_room_locking = false
  muc_tombstones = false


