import { cms } from './payload'
import { runpodConfiguration, scanTranscriptions } from './transcription'

const lifecycle = globalThis as typeof globalThis & {
  gdayTranscriptionWorker?: boolean
}
export function startTranscriptionWorker() {
  if (lifecycle.gdayTranscriptionWorker || !runpodConfiguration()) return
  lifecycle.gdayTranscriptionWorker = true
  const tick = async () => {
    try {
      await scanTranscriptions(await cms())
    } catch {
      console.error('Transcription recovery scan failed')
    }
    const timer = setTimeout(tick, 5_000)
    timer.unref()
  }
  const timer = setTimeout(tick, 0)
  timer.unref()
}
