import { sql } from '@payloadcms/db-postgres'
import type { Payload } from 'payload'

/** One statement is the concurrency boundary. Payload updateMany reads rows first. */
async function execute(payload: Payload, statement: ReturnType<typeof sql>) {
  const db = payload.db as unknown as {
    name: string
    drizzle: {
      execute: (query: ReturnType<typeof sql>) => Promise<unknown>
      run: (query: ReturnType<typeof sql>) => Promise<unknown>
    }
  }
  if (db.name === 'sqlite') await db.drizzle.run(statement)
  else await db.drizzle.execute(statement)
}

export async function projectTranscript(
  payload: Payload,
  taskId: string,
  meetingId: string,
  transcript: string,
) {
  // Compare the version on the target row itself: PostgreSQL rechecks this
  // predicate after waiting for a concurrent row update. No subquery snapshot.
  const task = await payload.findByID({
    collection: 'tasks',
    id: taskId,
    depth: 0,
    overrideAccess: true,
  })
  const order = task.createdAt + ':' + taskId
  await execute(
    payload,
    sql`UPDATE tasks SET status = 'COMPLETED', updated_at = ${new Date().toISOString()} WHERE id = ${taskId}`,
  )
  await execute(
    payload,
    sql`UPDATE meetings SET transcript = ${transcript}, transcript_task_order=${order}, updated_at = ${new Date().toISOString()}
    WHERE id = ${meetingId} AND (transcript_task_order IS NULL OR transcript_task_order <= ${order})`,
  )
}

export async function patchTask(
  payload: Payload,
  id: string,
  data: { status?: 'PENDING' | 'FAILED'; error?: string; runpodJobId?: string },
) {
  const fields = [sql`updated_at = ${new Date().toISOString()}`]
  if (data.status !== undefined) fields.push(sql`status = ${data.status}`)
  if (data.error !== undefined) fields.push(sql`error = ${data.error}`)
  if (data.runpodJobId !== undefined)
    fields.push(sql`runpod_job_id = ${data.runpodJobId}`)
  await execute(
    payload,
    sql`UPDATE tasks SET ${sql.join(fields, sql`, `)} WHERE id = ${id} AND status <> 'COMPLETED'`,
  )
}
