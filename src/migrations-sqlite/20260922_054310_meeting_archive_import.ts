import { MigrateUpArgs, MigrateDownArgs, sql } from '@payloadcms/db-sqlite'

export async function up({ db, payload, req }: MigrateUpArgs): Promise<void> {
  await db.run(sql`CREATE TABLE \`meetings_archive_audio\` (
  	\`_order\` integer NOT NULL,
  	\`_parent_id\` text(36) NOT NULL,
  	\`id\` text PRIMARY KEY NOT NULL,
  	\`audio_id\` text(36),
  	\`filename\` text NOT NULL,
  	\`sha256\` text NOT NULL,
  	\`size\` numeric NOT NULL,
  	FOREIGN KEY (\`audio_id\`) REFERENCES \`audio_files\`(\`id\`) ON UPDATE no action ON DELETE set null,
  	FOREIGN KEY (\`_parent_id\`) REFERENCES \`meetings\`(\`id\`) ON UPDATE no action ON DELETE cascade
  );
  `)
  await db.run(sql`CREATE INDEX \`meetings_archive_audio_order_idx\` ON \`meetings_archive_audio\` (\`_order\`);`)
  await db.run(sql`CREATE INDEX \`meetings_archive_audio_parent_id_idx\` ON \`meetings_archive_audio\` (\`_parent_id\`);`)
  await db.run(sql`CREATE INDEX \`meetings_archive_audio_audio_idx\` ON \`meetings_archive_audio\` (\`audio_id\`);`)
  await db.run(sql`ALTER TABLE \`meetings\` ADD \`import_key\` text;`)
  await db.run(sql`ALTER TABLE \`meetings\` ADD \`import_digest\` text;`)
  await db.run(sql`ALTER TABLE \`meetings\` ADD \`archive_metadata\` text;`)
  await db.run(sql`ALTER TABLE \`meetings\` ADD \`archive_artifacts\` text;`)
  await db.run(sql`CREATE INDEX \`meetings_import_key_idx\` ON \`meetings\` (\`import_key\`);`)
}

export async function down({ db, payload, req }: MigrateDownArgs): Promise<void> {
  await db.run(sql`DROP TABLE \`meetings_archive_audio\`;`)
  await db.run(sql`DROP INDEX \`meetings_import_key_idx\`;`)
  await db.run(sql`ALTER TABLE \`meetings\` DROP COLUMN \`import_key\`;`)
  await db.run(sql`ALTER TABLE \`meetings\` DROP COLUMN \`import_digest\`;`)
  await db.run(sql`ALTER TABLE \`meetings\` DROP COLUMN \`archive_metadata\`;`)
  await db.run(sql`ALTER TABLE \`meetings\` DROP COLUMN \`archive_artifacts\`;`)
}
