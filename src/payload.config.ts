import { serverEnv } from './lib/env'
import { mkdirSync } from 'node:fs'
import path from 'node:path'
import { buildConfig } from 'payload'
import { sqliteAdapter } from '@payloadcms/db-sqlite'
import { postgresAdapter } from '@payloadcms/db-postgres'
import { migrations as sqliteMigrations } from './migrations-sqlite'
import { migrations as postgresMigrations } from './migrations-postgres'
import {
  Users,
  Meetings,
  Tasks,
  Outputs,
  AudioFiles,
} from './collections/index'

const env = serverEnv()
const dataDir = env.DATA_DIR
mkdirSync(dataDir, { recursive: true })
const secret = env.PAYLOAD_SECRET
const adapter = env.DATABASE_ADAPTER
export default buildConfig({
  secret,
  serverURL: env.SERVER_URL,
  admin: { user: 'users', meta: { titleSuffix: ' · GdayMeetings' } },
  collections: [Users, Meetings, Tasks, Outputs, AudioFiles],
  db:
    adapter === 'postgres'
      ? postgresAdapter({
          pool: { connectionString: env.DATABASE_URI },
          idType: 'uuid',
          migrationDir: path.resolve('src/migrations-postgres'),
          prodMigrations: postgresMigrations,
          push: process.env.NODE_ENV !== 'production',
        })
      : sqliteAdapter({
          client: {
            url: env.DATABASE_URI || `file:${dataDir}/gday.db`,
          },
          idType: 'uuid',
          migrationDir: path.resolve('src/migrations-sqlite'),
          prodMigrations: sqliteMigrations,
          push: process.env.NODE_ENV !== 'production',
          wal: true,
          busyTimeout: 5000,
          transactionOptions: { behavior: 'immediate' },
        }),
  typescript: { outputFile: path.resolve('src/payload-types.ts') },
})
