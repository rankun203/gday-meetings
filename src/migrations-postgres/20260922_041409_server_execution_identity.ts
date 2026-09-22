import { MigrateUpArgs, MigrateDownArgs, sql } from '@payloadcms/db-postgres'

export async function up({ db, payload, req }: MigrateUpArgs): Promise<void> {
  await db.execute(sql`
   CREATE TYPE "public"."enum_users_role" AS ENUM('admin', 'member');
  ALTER TABLE "users" ADD COLUMN "role" "enum_users_role" DEFAULT 'member' NOT NULL;
  -- Preserve existing full administrators; only newly created accounts default to member.
  UPDATE "users" SET "role" = 'admin';
  ALTER TABLE "users" ADD COLUMN "disabled" boolean DEFAULT false;
  ALTER TABLE "tasks" ADD COLUMN "execution_state" varchar;
  ALTER TABLE "tasks" ADD COLUMN "execution_options" jsonb;
  ALTER TABLE "tasks" ADD COLUMN "execution_revision" numeric DEFAULT 0;
  ALTER TABLE "tasks" ADD COLUMN "submission_started_at" timestamp(3) with time zone;
  ALTER TABLE "tasks" ADD COLUMN "next_poll_at" timestamp(3) with time zone;
  ALTER TABLE "tasks" ADD COLUMN "idempotency_key" varchar;
  ALTER TABLE "tasks" ADD COLUMN "request_hash" varchar;
  CREATE INDEX "tasks_execution_state_idx" ON "tasks" USING btree ("execution_state");
  CREATE INDEX "tasks_next_poll_at_idx" ON "tasks" USING btree ("next_poll_at");
  CREATE UNIQUE INDEX "tasks_idempotency_key_idx" ON "tasks" USING btree ("idempotency_key");`)
}

export async function down({ db, payload, req }: MigrateDownArgs): Promise<void> {
  await db.execute(sql`
   DROP INDEX "tasks_execution_state_idx";
  DROP INDEX "tasks_next_poll_at_idx";
  DROP INDEX "tasks_idempotency_key_idx";
  ALTER TABLE "users" DROP COLUMN "role";
  ALTER TABLE "users" DROP COLUMN "disabled";
  ALTER TABLE "tasks" DROP COLUMN "execution_state";
  ALTER TABLE "tasks" DROP COLUMN "execution_options";
  ALTER TABLE "tasks" DROP COLUMN "execution_revision";
  ALTER TABLE "tasks" DROP COLUMN "submission_started_at";
  ALTER TABLE "tasks" DROP COLUMN "next_poll_at";
  ALTER TABLE "tasks" DROP COLUMN "idempotency_key";
  ALTER TABLE "tasks" DROP COLUMN "request_hash";
  DROP TYPE "public"."enum_users_role";`)
}
