CREATE TABLE IF NOT EXISTS "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE IF NOT EXISTS "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE IF NOT EXISTS "accounts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL, "join_code" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "custom_styles" text /*application='Campfire'*/);
CREATE TABLE IF NOT EXISTS "action_text_rich_texts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL, "body" text, "record_type" varchar NOT NULL, "record_id" bigint NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_action_text_rich_texts_uniqueness" ON "action_text_rich_texts" ("record_type", "record_id", "name") /*application='Campfire'*/;
CREATE TABLE IF NOT EXISTS "memberships" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "room_id" integer NOT NULL, "user_id" integer NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "unread_at" datetime(6), "involvement" varchar DEFAULT 'mentions', "connections" integer DEFAULT 0 NOT NULL, "connected_at" datetime(6));
CREATE INDEX "index_memberships_on_room_id_and_created_at" ON "memberships" ("room_id", "created_at") /*application='Campfire'*/;
CREATE UNIQUE INDEX "index_memberships_on_room_id_and_user_id" ON "memberships" ("room_id", "user_id") /*application='Campfire'*/;
CREATE INDEX "index_memberships_on_room_id" ON "memberships" ("room_id") /*application='Campfire'*/;
CREATE INDEX "index_memberships_on_user_id" ON "memberships" ("user_id") /*application='Campfire'*/;
CREATE TABLE IF NOT EXISTS "rooms" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "type" varchar NOT NULL, "creator_id" bigint NOT NULL);
CREATE TABLE IF NOT EXISTS "active_storage_attachments" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL, "record_type" varchar NOT NULL, "record_id" bigint NOT NULL, "blob_id" bigint NOT NULL, "created_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_c3b3935057"
FOREIGN KEY ("blob_id")
  REFERENCES "active_storage_blobs" ("id")
);
CREATE INDEX "index_active_storage_attachments_on_blob_id" ON "active_storage_attachments" ("blob_id") /*application='Campfire'*/;
CREATE UNIQUE INDEX "index_active_storage_attachments_uniqueness" ON "active_storage_attachments" ("record_type", "record_id", "name", "blob_id") /*application='Campfire'*/;
CREATE TABLE IF NOT EXISTS "active_storage_variant_records" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "blob_id" bigint NOT NULL, "variation_digest" varchar NOT NULL, CONSTRAINT "fk_rails_993965df05"
FOREIGN KEY ("blob_id")
  REFERENCES "active_storage_blobs" ("id")
);
CREATE UNIQUE INDEX "index_active_storage_variant_records_uniqueness" ON "active_storage_variant_records" ("blob_id", "variation_digest") /*application='Campfire'*/;
CREATE TABLE IF NOT EXISTS "boosts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "message_id" integer NOT NULL, "booster_id" integer NOT NULL, "content" varchar(16) NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_3539c52d73"
FOREIGN KEY ("message_id")
  REFERENCES "messages" ("id")
);
CREATE INDEX "index_boosts_on_booster_id" ON "boosts" ("booster_id") /*application='Campfire'*/;
CREATE INDEX "index_boosts_on_message_id" ON "boosts" ("message_id") /*application='Campfire'*/;
CREATE TABLE IF NOT EXISTS "messages" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "room_id" integer NOT NULL, "creator_id" integer NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "client_message_id" varchar NOT NULL, CONSTRAINT "fk_rails_a8db0fb63a"
FOREIGN KEY ("room_id")
  REFERENCES "rooms" ("id")
, CONSTRAINT "fk_rails_761a2f12b3"
FOREIGN KEY ("creator_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_messages_on_creator_id" ON "messages" ("creator_id") /*application='Campfire'*/;
CREATE INDEX "index_messages_on_room_id" ON "messages" ("room_id") /*application='Campfire'*/;
CREATE TABLE IF NOT EXISTS "push_subscriptions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "user_id" integer NOT NULL, "endpoint" varchar, "p256dh_key" varchar, "auth_key" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "user_agent" varchar, CONSTRAINT "fk_rails_43d43720fc"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "idx_on_endpoint_p256dh_key_auth_key_7553014576" ON "push_subscriptions" ("endpoint", "p256dh_key", "auth_key") /*application='Campfire'*/;
CREATE INDEX "index_push_subscriptions_on_user_id" ON "push_subscriptions" ("user_id") /*application='Campfire'*/;
CREATE TABLE IF NOT EXISTS "searches" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "user_id" integer NOT NULL, "query" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_e192b86393"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_searches_on_user_id" ON "searches" ("user_id") /*application='Campfire'*/;
CREATE VIRTUAL TABLE message_search_index using fts5(body, tokenize=porter)
/* message_search_index(body) */;
CREATE TABLE IF NOT EXISTS 'message_search_index_data'(id INTEGER PRIMARY KEY, block BLOB);
CREATE TABLE IF NOT EXISTS 'message_search_index_idx'(segid, term, pgno, PRIMARY KEY(segid, term)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS 'message_search_index_content'(id INTEGER PRIMARY KEY, c0);
CREATE TABLE IF NOT EXISTS 'message_search_index_docsize'(id INTEGER PRIMARY KEY, sz BLOB);
CREATE TABLE IF NOT EXISTS 'message_search_index_config'(k PRIMARY KEY, v) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS "sessions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "user_id" integer NOT NULL, "token" varchar NOT NULL, "ip_address" varchar, "user_agent" varchar, "last_active_at" datetime(6) NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_758836b4f0"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_sessions_on_user_id" ON "sessions" ("user_id") /*application='Campfire'*/;
CREATE UNIQUE INDEX "index_sessions_on_token" ON "sessions" ("token") /*application='Campfire'*/;
CREATE TABLE IF NOT EXISTS "webhooks" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "user_id" integer NOT NULL, "url" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_51bf96d3bc"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_webhooks_on_user_id" ON "webhooks" ("user_id") /*application='Campfire'*/;
CREATE TABLE IF NOT EXISTS "users" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "role" integer DEFAULT 0 NOT NULL, "email_address" varchar, "password_digest" varchar, "active" boolean DEFAULT TRUE, "bio" text, "bot_token" varchar, "banned" boolean DEFAULT FALSE NOT NULL /*application='Campfire'*/);
CREATE UNIQUE INDEX "index_users_on_email_address" ON "users" ("email_address") /*application='Campfire'*/;
CREATE UNIQUE INDEX "index_users_on_bot_token" ON "users" ("bot_token") /*application='Campfire'*/;
CREATE TABLE IF NOT EXISTS "active_storage_blobs" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "key" varchar NOT NULL, "filename" varchar NOT NULL, "content_type" varchar, "metadata" text, "service_name" varchar NOT NULL, "byte_size" bigint NOT NULL, "checksum" varchar, "created_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_active_storage_blobs_on_key" ON "active_storage_blobs" ("key") /*application='Campfire'*/;
INSERT INTO "schema_migrations" (version) VALUES
('20250924150000'),
('20250825100959'),
('20250825100958'),
('20250825100957'),
('20240209110503'),
('20240131105830'),
('20240130213001'),
('20240130003150'),
('20240115124901'),
('20240110071740'),
('20231220143106'),
('20231215043540');

