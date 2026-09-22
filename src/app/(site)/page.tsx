export default function Home() {
  return (
    <main>
      <p className="eyebrow">GDAY / MEETINGS</p>
      <h1>
        Every meeting.
        <br />A lasting record.
      </h1>
      <p className="intro">
        Recordings, processing tasks, and transcripts in one durable home. Built
        for people and the agents that help them.
      </p>
      <a className="button" href="/admin">
        Open your workspace ↗
      </a>
      <section>
        <article>
          <span>01 / CAPTURE</span>
          <h2>Keep the original.</h2>
          <p>
            Audio stays attached to its processing task, with private, scoped
            download links.
          </p>
        </article>
        <article>
          <span>02 / UNDERSTAND</span>
          <h2>Results that stay.</h2>
          <p>
            Workers save outputs here before returning. Transcripts survive
            expired job responses.
          </p>
        </article>
        <article>
          <span>03 / FIND</span>
          <h2>Recall what matters.</h2>
          <p>
            Search meeting titles and transcripts from the workspace or the
            dedicated MCP tool.
          </p>
        </article>
      </section>
      <footer>GdayMeetings · Your meeting memory</footer>
    </main>
  )
}
