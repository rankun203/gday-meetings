import { serverEnv } from '../lib/env'
import { randomUUID } from 'node:crypto'
import path from 'node:path'
import type {
  CollectionBeforeOperationHook,
  CollectionBeforeValidateHook,
} from 'payload'
import { APIError } from 'payload'

const extensions = new Set([
  '.wav',
  '.flac',
  '.mp3',
  '.m4a',
  '.ogg',
  '.opus',
  '.mp4',
  '.webm',
  '.aac',
])
export const prepareAudio: CollectionBeforeOperationHook = ({
  args,
  operation,
  req,
}) => {
  if (operation !== 'create' && operation !== 'update') return args
  if (operation === 'update' && req.file)
    throw new APIError(
      'Upload a new audio file instead of replacing a recording used by a task.',
      400,
    )
  if (req.file) {
    const file = req.file
    const extension = path.extname(file.name).toLowerCase()
    if (!extensions.has(extension))
      throw new APIError('Unsupported audio extension', 400)
    if (!file.size || file.size > serverEnv().MAX_UPLOAD_BYTES)
      throw new APIError(
        'Audio is empty or exceeds the configured upload limit (maximum 500 MB). Prefer Opus, M4A or MP3.',
        file.size ? 413 : 400,
      )
    req.context.originalAudioName = path.basename(file.name)
    file.name = randomUUID() + extension
  }
  return args
}
export const audioMetadata: CollectionBeforeValidateHook = ({
  data,
  req,
  originalDoc,
}) => {
  if (!data) return data
  if (req.file) {
    data.storageKey = data.filename
    data.originalName = req.context.originalAudioName
    data.size = data.filesize
    data.contentType = data.mimeType
  } else if (originalDoc) {
    for (const field of [
      'storageKey',
      'originalName',
      'size',
      'contentType',
      'filename',
      'filesize',
      'mimeType',
      'url',
      'thumbnailURL',
      'width',
      'height',
    ])
      data[field] = originalDoc[field]
  }
  return data
}
