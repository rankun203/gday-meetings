import assert from 'node:assert/strict'

const origin = 'http://127.0.0.1:37139'
const credentials = {
  email: 'audio-smoke@example.test',
  password: 'synthetic-test-password-12345',
}
const call = (path, body) =>
  fetch(origin + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Origin: origin },
    body: JSON.stringify(body),
  })
const first = await call('/api/users/first-register', credentials)
assert.equal(first.status, 200, await first.clone().text())
const login = await call('/api/users/login', credentials)
assert.equal(login.status, 200)
const cookie = login.headers
  .getSetCookie()
  .map((v) => v.split(';')[0])
  .join('; ')
// Check rendered cards: missing import-map entries can still return HTTP 200.
const dashboard = await fetch(origin + '/admin', {
  headers: { Cookie: cookie, Origin: origin },
  redirect: 'manual',
})
assert.equal(dashboard.status, 200)
const html = await dashboard.text()
for (const collection of ['users', 'meetings', 'tasks', 'outputs', 'audio-files']) {
  assert.ok(html.includes('id="card-' + collection + '"'),
    'Admin dashboard did not render the ' + collection + ' collection card')
}
const bytes = Buffer.alloc(60)
bytes.write('RIFF')
bytes.writeUInt32LE(52, 4)
bytes.write('WAVEfmt ', 8)
bytes.writeUInt32LE(16, 16)
bytes.writeUInt16LE(1, 20)
bytes.writeUInt16LE(1, 22)
bytes.writeUInt32LE(8000, 24)
bytes.writeUInt32LE(16000, 28)
bytes.writeUInt16LE(2, 32)
bytes.writeUInt16LE(16, 34)
bytes.write('data', 36)
bytes.writeUInt32LE(16, 40)
const data = new FormData()
data.append('_payload', '{}')
data.append(
  'file',
  new Blob([bytes], { type: 'audio/wav' }),
  'container-recording.wav',
)
const upload = await fetch(origin + '/api/audio-files', {
  method: 'POST',
  headers: { Cookie: cookie, Origin: origin },
  body: data,
})
assert.equal(upload.status, 201, await upload.clone().text())
const { doc } = await upload.json()
assert.equal(doc.originalName, 'container-recording.wav')
assert.equal(doc.filesize, bytes.length)
assert.equal(doc.storageKey, doc.filename)
assert.match(doc.filename, /^[0-9a-f-]{36}\.wav$/)
const download = await fetch(doc.url, {
  headers: { Cookie: cookie, Origin: origin },
})
assert.equal(download.status, 200)
assert.deepEqual(Buffer.from(await download.arrayBuffer()), bytes)
assert.notEqual((await fetch(doc.url)).status, 200)
const removed = await fetch(origin + '/api/audio-files/' + doc.id, {
  method: 'DELETE',
  headers: { Cookie: cookie, Origin: origin },
})
assert.equal(removed.status, 200, await removed.clone().text())
assert.notEqual(
  (await fetch(doc.url, { headers: { Cookie: cookie, Origin: origin } }))
    .status,
  200,
)
console.log(
  'Published image: authenticated dashboard cards, multipart CMS upload, generated metadata, authenticated byte-exact download, anonymous denial and file deletion PASS',
)
