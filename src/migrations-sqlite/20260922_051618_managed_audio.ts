import { MigrateUpArgs, MigrateDownArgs, sql } from '@payloadcms/db-sqlite'

export async function up({ db, payload, req }: MigrateUpArgs): Promise<void> {
  await db.run(sql`ALTER TABLE \`audio_files\` ADD \`url\` text;`)
  await db.run(sql`ALTER TABLE \`audio_files\` ADD \`thumbnail_u_r_l\` text;`)
  await db.run(sql`ALTER TABLE \`audio_files\` ADD \`filename\` text;`)
  await db.run(sql`ALTER TABLE \`audio_files\` ADD \`mime_type\` text;`)
  await db.run(sql`ALTER TABLE \`audio_files\` ADD \`filesize\` numeric;`)
  await db.run(sql`ALTER TABLE \`audio_files\` ADD \`width\` numeric;`)
  await db.run(sql`ALTER TABLE \`audio_files\` ADD \`height\` numeric;`)
  await db.run(sql`CREATE UNIQUE INDEX \`audio_files_filename_idx\` ON \`audio_files\` (\`filename\`);`)
  await db.run(sql`UPDATE audio_files SET filename = storage_key, mime_type = content_type, filesize = size, url = '/api/audio-files/file/' || storage_key;`)
}

export async function down({ db, payload, req }: MigrateDownArgs): Promise<void> {
  await db.run(sql`DROP INDEX \`audio_files_filename_idx\`;`)
  await db.run(sql`ALTER TABLE \`audio_files\` DROP COLUMN \`url\`;`)
  await db.run(sql`ALTER TABLE \`audio_files\` DROP COLUMN \`thumbnail_u_r_l\`;`)
  await db.run(sql`ALTER TABLE \`audio_files\` DROP COLUMN \`filename\`;`)
  await db.run(sql`ALTER TABLE \`audio_files\` DROP COLUMN \`mime_type\`;`)
  await db.run(sql`ALTER TABLE \`audio_files\` DROP COLUMN \`filesize\`;`)
  await db.run(sql`ALTER TABLE \`audio_files\` DROP COLUMN \`width\`;`)
  await db.run(sql`ALTER TABLE \`audio_files\` DROP COLUMN \`height\`;`)
}
