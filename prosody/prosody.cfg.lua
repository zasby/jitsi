admins = {}

modules_enabled = {
  "websocket";
  "bosh";
  "smacks";
  "ping";
  "external_services"; -- реклама STUN/TURN
  "roster";
  "pep";
  "private";
  "blocklist";
  "vcard4";
  "vcard_legacy";
  "muc";
  "limits";
  "csi_simple";
  "mam";
  "http";
}

modules_disabled = {
  "posix";
}

http_ports = { 5280 }
cross_domain_websocket = true
consider_bosh_secure = true

VirtualHost "connect.mooz.pro"
  authentication = "anonymous"
  allow_unencrypted_plain_auth = true
  ssl = { }
  modules_enabled = {
    "websocket"; "bosh"; "ping"; "smacks"; "mam";
  }
  external_services = {
    { type = "stun", host = "turn.connect.mooz.pro", port = 3478 };
    { type = "turn", host = "turn.connect.mooz.pro", port = 3478, transport = "udp",
      username = "turnuser", password = "turnpass" };
    -- { type = "turns", host = "connect.mooz.pro", port = 5349, transport = "tcp",
    --   username = "turnuser", password = "turnpass" };
  }

VirtualHost "auth.connect.mooz.pro"
  authentication = "internal_hashed"

Component "conference.connect.mooz.pro" "muc"
  restrict_room_creation = false
  max_history_messages = 0
  muc_room_locking = false
  muc_tombstones = false


