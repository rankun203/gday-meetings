import path from 'node:path'
import { unlink } from 'node:fs/promises'
export const audioDirectory = () =>
  path.join(process.env.DATA_DIR || path.resolve('data'), 'audio')
export const validStorageKey = (key: string) =>
  /^[0-9a-f-]{36}\.(wav|flac|mp3|m4a|ogg|opus|mp4|webm|aac)$/.test(key)
export async function removeAudio(key: string) {
  if (!validStorageKey(key)) throw new Error('Invalid audio storage key')
  try {
    await unlink(path.join(audioDirectory(), key))
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }
}
