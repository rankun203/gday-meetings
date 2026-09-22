import { MigrateUpArgs, MigrateDownArgs, sql } from '@payloadcms/db-postgres'

export async function up({ db, payload, req }: MigrateUpArgs): Promise<void> {
  await db.execute(sql`
   CREATE TABLE "meetings_archive_audio" (
  	"_order" integer NOT NULL,
  	"_parent_id" uuid NOT NULL,
  	"id" varchar PRIMARY KEY NOT NULL,
  	"audio_id" uuid,
  	"filename" varchar NOT NULL,
  	"sha256" varchar NOT NULL,
  	"size" numeric NOT NULL
  );
  
  ALTER TABLE "meetings" ADD COLUMN "import_key" varchar;
  ALTER TABLE "meetings" ADD COLUMN "import_digest" varchar;
  ALTER TABLE "meetings" ADD COLUMN "archive_metadata" jsonb;
  ALTER TABLE "meetings" ADD COLUMN "archive_artifacts" jsonb;
  ALTER TABLE "meetings_archive_audio" ADD CONSTRAINT "meetings_archive_audio_audio_id_audio_files_id_fk" FOREIGN KEY ("audio_id") REFERENCES "public"."audio_files"("id") ON DELETE set null ON UPDATE no action;
  ALTER TABLE "meetings_archive_audio" ADD CONSTRAINT "meetings_archive_audio_parent_id_fk" FOREIGN KEY ("_parent_id") REFERENCES "public"."meetings"("id") ON DELETE cascade ON UPDATE no action;
  CREATE INDEX "meetings_archive_audio_order_idx" ON "meetings_archive_audio" USING btree ("_order");
  CREATE INDEX "meetings_archive_audio_parent_id_idx" ON "meetings_archive_audio" USING btree ("_parent_id");
  CREATE INDEX "meetings_archive_audio_audio_idx" ON "meetings_archive_audio" USING btree ("audio_id");
  CREATE INDEX "meetings_import_key_idx" ON "meetings" USING btree ("import_key");`)
}

export async function down({ db, payload, req }: MigrateDownArgs): Promise<void> {
  await db.execute(sql`
   ALTER TABLE "meetings_archive_audio" DISABLE ROW LEVEL SECURITY;
  DROP TABLE "meetings_archive_audio" CASCADE;
  DROP INDEX "meetings_import_key_idx";
  ALTER TABLE "meetings" DROP COLUMN "import_key";
  ALTER TABLE "meetings" DROP COLUMN "import_digest";
  ALTER TABLE "meetings" DROP COLUMN "archive_metadata";
  ALTER TABLE "meetings" DROP COLUMN "archive_artifacts";`)
}
