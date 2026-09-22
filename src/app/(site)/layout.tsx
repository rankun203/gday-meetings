import './style.css'
export const metadata = {
  title: 'GdayMeetings',
  description: 'Your recordings, tasks, and transcripts — durably together.',
}
export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  )
}
