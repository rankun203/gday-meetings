import * as migration_20260922_024348_initial_schema from './20260922_024348_initial_schema';
import * as migration_20260922_025208_transcript_projection_order from './20260922_025208_transcript_projection_order';

export const migrations = [
  {
    up: migration_20260922_024348_initial_schema.up,
    down: migration_20260922_024348_initial_schema.down,
    name: '20260922_024348_initial_schema',
  },
  {
    up: migration_20260922_025208_transcript_projection_order.up,
    down: migration_20260922_025208_transcript_projection_order.down,
    name: '20260922_025208_transcript_projection_order'
  },
];
