import { MigrateUpArgs, MigrateDownArgs, sql } from '@payloadcms/db-postgres'

export async function up({ db, payload, req }: MigrateUpArgs): Promise<void> {
  await db.execute(sql`
   ALTER TABLE "audio_files" ADD COLUMN "url" varchar;
  ALTER TABLE "audio_files" ADD COLUMN "thumbnail_u_r_l" varchar;
  ALTER TABLE "audio_files" ADD COLUMN "filename" varchar;
  ALTER TABLE "audio_files" ADD COLUMN "mime_type" varchar;
  ALTER TABLE "audio_files" ADD COLUMN "filesize" numeric;
  ALTER TABLE "audio_files" ADD COLUMN "width" numeric;
  ALTER TABLE "audio_files" ADD COLUMN "height" numeric;
  CREATE UNIQUE INDEX "audio_files_filename_idx" ON "audio_files" USING btree ("filename");`)
  await db.execute(sql`UPDATE audio_files SET filename = storage_key, mime_type = content_type, filesize = size, url = '/api/audio-files/file/' || storage_key;`)
}

export async function down({ db, payload, req }: MigrateDownArgs): Promise<void> {
  await db.execute(sql`
   DROP INDEX "audio_files_filename_idx";
  ALTER TABLE "audio_files" DROP COLUMN "url";
  ALTER TABLE "audio_files" DROP COLUMN "thumbnail_u_r_l";
  ALTER TABLE "audio_files" DROP COLUMN "filename";
  ALTER TABLE "audio_files" DROP COLUMN "mime_type";
  ALTER TABLE "audio_files" DROP COLUMN "filesize";
  ALTER TABLE "audio_files" DROP COLUMN "width";
  ALTER TABLE "audio_files" DROP COLUMN "height";`)
}
