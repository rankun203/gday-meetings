import { config as loadEnv } from 'dotenv'
loadEnv({ quiet: true })
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

const dataDir = process.env.DATA_DIR || path.resolve('data')
mkdirSync(dataDir, { recursive: true })
const secret = process.env.PAYLOAD_SECRET
if (!secret || secret.length < 32)
  throw new Error(
    'Set PAYLOAD_SECRET to at least 32 random characters (see .env.example).',
  )
const adapter = process.env.DATABASE_ADAPTER || 'sqlite'
if (!['sqlite', 'postgres'].includes(adapter))
  throw new Error('DATABASE_ADAPTER must be sqlite or postgres')
export default buildConfig({
  secret,
  serverURL: process.env.SERVER_URL || 'http://localhost:3000',
  admin: { user: 'users', meta: { titleSuffix: ' · GdayMeetings' } },
  collections: [Users, Meetings, Tasks, Outputs, AudioFiles],
  db:
    adapter === 'postgres'
      ? postgresAdapter({
          pool: { connectionString: process.env.DATABASE_URI },
          idType: 'uuid',
          migrationDir: path.resolve('src/migrations-postgres'),
          prodMigrations: postgresMigrations,
          push: process.env.NODE_ENV !== 'production',
        })
      : sqliteAdapter({
          client: {
            url: process.env.DATABASE_URI || `file:${dataDir}/gday.db`,
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
