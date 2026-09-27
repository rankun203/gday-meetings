import { createHash } from 'node:crypto'
import { z } from 'zod'

export const archiveImagePath =
  /^assets\/(?:[^/\\]+\/)*[^/\\]+\.(png|jpe?g|gif|webp|heic|heif|tiff?|bmp)$/i
const imageTypes: Record<string, string[]> = {
  png: ['image/png'],
  jpg: ['image/jpeg'],
  jpeg: ['image/jpeg'],
  gif: ['image/gif'],
  webp: ['image/webp'],
  heic: ['image/heic'],
  heif: ['image/heif'],
  tif: ['image/tiff'],
  tiff: ['image/tiff'],
  bmp: ['image/bmp'],
}

export const archiveImage = z
  .object({
    encoding: z.literal('base64'),
    mediaType: z.string(),
    data: z.string().max(20 * 1024 * 1024),
    sha256: z.string().regex(/^[a-f0-9]{64}$/),
    size: z
      .number()
      .int()
      .positive()
      .max(15 * 1024 * 1024),
  })
  .strict()

/** Only raster files are downloadable. Never serve arbitrary HTML or SVG. */
export function decodeArchiveImage(
  name: string,
  value: unknown,
): Buffer | null {
  let decoded: string
  try {
    decoded = decodeURIComponent(name)
  } catch {
    return null
  }
  if (
    name.length > 255 ||
    !archiveImagePath.test(name) ||
    /[\x00-\x1f\x7f]/.test(name) ||
    name
      .split('/')
      .some((part) => part === '.' || part === '..' || part.length === 0)
  )
    return null
  if (
    decoded.includes('\\') ||
    decoded.split('/').some((part) => part === '.' || part === '..')
  )
    return null
  const parsed = archiveImage.safeParse(value)
  if (!parsed.success) return null
  const image = parsed.data
  const extension = name.split('.').pop()!.toLowerCase()
  if (!imageTypes[extension]?.includes(image.mediaType)) return null
  const bytes = Buffer.from(image.data, 'base64')
  if (
    bytes.length !== image.size ||
    bytes.toString('base64') !== image.data ||
    createHash('sha256').update(bytes).digest('hex') !== image.sha256
  )
    return null
  const hex = bytes.subarray(0, 12).toString('hex')
  const ascii = bytes.subarray(0, 12).toString('ascii')
  const signatures: Record<string, boolean> = {
    'image/png': hex.startsWith('89504e470d0a1a0a'),
    'image/jpeg': hex.startsWith('ffd8ff'),
    'image/gif': ascii.startsWith('GIF87a') || ascii.startsWith('GIF89a'),
    'image/webp': ascii.startsWith('RIFF') && ascii.slice(8) === 'WEBP',
    'image/tiff': hex.startsWith('49492a00') || hex.startsWith('4d4d002a'),
    'image/bmp': ascii.startsWith('BM'),
    'image/heic':
      ascii.slice(4, 8) === 'ftyp' &&
      ['heic', 'heix', 'hevc', 'hevx', 'mif1'].includes(ascii.slice(8)),
    'image/heif':
      ascii.slice(4, 8) === 'ftyp' &&
      ['heic', 'heix', 'hevc', 'hevx', 'mif1', 'msf1'].includes(ascii.slice(8)),
  }
  return signatures[image.mediaType] ? bytes : null
}

export const archiveArtifacts = z
  .record(z.string().max(255), z.json())
  .superRefine((values, context) => {
    for (const [name, value] of Object.entries(values)) {
      if (/^[^./\\][^/\\]*\.(json|md|txt)$/.test(name) && value !== null)
        continue
      if (decodeArchiveImage(name, value)) continue
      context.addIssue({
        code: 'custom',
        path: [name],
        message: 'Invalid archive artifact or image checksum',
      })
    }
  })
