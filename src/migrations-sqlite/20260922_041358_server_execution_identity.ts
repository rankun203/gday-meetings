import { MigrateUpArgs, MigrateDownArgs, sql } from '@payloadcms/db-sqlite'

export async function up({ db, payload, req }: MigrateUpArgs): Promise<void> {
  await db.run(sql`ALTER TABLE \`users\` ADD \`role\` text DEFAULT 'member' NOT NULL;`)
  // Before roles, every authenticated account already had full administrator access.
  await db.run(sql`UPDATE \`users\` SET \`role\` = 'admin';`)
  await db.run(sql`ALTER TABLE \`users\` ADD \`disabled\` integer DEFAULT false;`)
  await db.run(sql`ALTER TABLE \`tasks\` ADD \`execution_state\` text;`)
  await db.run(sql`ALTER TABLE \`tasks\` ADD \`execution_options\` text;`)
  await db.run(sql`ALTER TABLE \`tasks\` ADD \`execution_revision\` numeric DEFAULT 0;`)
  await db.run(sql`ALTER TABLE \`tasks\` ADD \`submission_started_at\` text;`)
  await db.run(sql`ALTER TABLE \`tasks\` ADD \`next_poll_at\` text;`)
  await db.run(sql`ALTER TABLE \`tasks\` ADD \`idempotency_key\` text;`)
  await db.run(sql`ALTER TABLE \`tasks\` ADD \`request_hash\` text;`)
  await db.run(sql`CREATE INDEX \`tasks_execution_state_idx\` ON \`tasks\` (\`execution_state\`);`)
  await db.run(sql`CREATE INDEX \`tasks_next_poll_at_idx\` ON \`tasks\` (\`next_poll_at\`);`)
  await db.run(sql`CREATE UNIQUE INDEX \`tasks_idempotency_key_idx\` ON \`tasks\` (\`idempotency_key\`);`)
}

export async function down({ db, payload, req }: MigrateDownArgs): Promise<void> {
  await db.run(sql`DROP INDEX \`tasks_execution_state_idx\`;`)
  await db.run(sql`DROP INDEX \`tasks_next_poll_at_idx\`;`)
  await db.run(sql`DROP INDEX \`tasks_idempotency_key_idx\`;`)
  await db.run(sql`ALTER TABLE \`tasks\` DROP COLUMN \`execution_state\`;`)
  await db.run(sql`ALTER TABLE \`tasks\` DROP COLUMN \`execution_options\`;`)
  await db.run(sql`ALTER TABLE \`tasks\` DROP COLUMN \`execution_revision\`;`)
  await db.run(sql`ALTER TABLE \`tasks\` DROP COLUMN \`submission_started_at\`;`)
  await db.run(sql`ALTER TABLE \`tasks\` DROP COLUMN \`next_poll_at\`;`)
  await db.run(sql`ALTER TABLE \`tasks\` DROP COLUMN \`idempotency_key\`;`)
  await db.run(sql`ALTER TABLE \`tasks\` DROP COLUMN \`request_hash\`;`)
  await db.run(sql`ALTER TABLE \`users\` DROP COLUMN \`role\`;`)
  await db.run(sql`ALTER TABLE \`users\` DROP COLUMN \`disabled\`;`)
}
