import * as migration_20260922_024348_initial_schema from './20260922_024348_initial_schema';
import * as migration_20260922_025208_transcript_projection_order from './20260922_025208_transcript_projection_order';
import * as migration_20260922_041409_server_execution_identity from './20260922_041409_server_execution_identity';
import * as migration_20260922_051634_managed_audio from './20260922_051634_managed_audio';
import * as migration_20260922_054312_meeting_archive_import from './20260922_054312_meeting_archive_import';

export const migrations = [
  {
    up: migration_20260922_024348_initial_schema.up,
    down: migration_20260922_024348_initial_schema.down,
    name: '20260922_024348_initial_schema',
  },
  {
    up: migration_20260922_025208_transcript_projection_order.up,
    down: migration_20260922_025208_transcript_projection_order.down,
    name: '20260922_025208_transcript_projection_order',
  },
  {
    up: migration_20260922_041409_server_execution_identity.up,
    down: migration_20260922_041409_server_execution_identity.down,
    name: '20260922_041409_server_execution_identity',
  },
  {
    up: migration_20260922_051634_managed_audio.up,
    down: migration_20260922_051634_managed_audio.down,
    name: '20260922_051634_managed_audio',
  },
  {
    up: migration_20260922_054312_meeting_archive_import.up,
    down: migration_20260922_054312_meeting_archive_import.down,
    name: '20260922_054312_meeting_archive_import',
  },
];
