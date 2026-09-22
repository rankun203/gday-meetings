import { withPayload } from '@payloadcms/next/withPayload'
export default withPayload({
  output: 'standalone',
  poweredByHeader: false,
  async headers() {
    return ['/sign-in', '/consent', '/account', '/api/auth/:path*'].map(
      (source) => ({
        source,
        headers: [
          { key: 'Cache-Control', value: 'no-store' },
          { key: 'Content-Security-Policy', value: "frame-ancestors 'none'" },
          { key: 'X-Frame-Options', value: 'DENY' },
          { key: 'Referrer-Policy', value: 'no-referrer' },
        ],
      }),
    )
  },
})
