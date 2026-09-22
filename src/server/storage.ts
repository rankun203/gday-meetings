import path from 'node:path'
export const audioDirectory = () =>
  path.join(process.env.DATA_DIR || path.resolve('data'), 'audio')
