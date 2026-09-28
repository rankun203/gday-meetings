//! Meeting transcript summarization via LLM.
//!
//! Reads a session's transcript, formats it with full meeting context
//! (participants, title, notes), builds a system prompt with metadata,
//! and calls the LLM to produce a summary saved as `summary.json`.

use std::collections::BTreeSet;
use std::path::Path;

use chrono::{DateTime, Local, Utc};
use futures::StreamExt;
use serde_json::{Value, json};
use tracing::{info, warn};

use crate::llm::client::LlmClient;
use crate::llm::context::{collect_tag_notes, collect_person_notes, extract_person_ids};
use crate::llm::prompt::format_segment;
use crate::people::PeopleManager;
use crate::session::SessionManager;
use crate::session::session::SessionInfo;
use crate::tags::TagsManager;

/// Metadata about the session passed to the summarization prompt.
pub struct SummarizationContext<'a> {
    pub session_info: Option<&'a SessionInfo>,
    pub language: &'a str,
}

/// Build the full system prompt for summarization.
///
/// Contains the complete default instructions. The user's custom prompt
/// (from the PROMPT settings field) is appended as additional instructions
/// if non-empty.
pub fn build_system_prompt(user_prompt: &str, ctx: &SummarizationContext) -> String {
    // 1. Task
    let mut prompt = String::from(
"You are a meeting summarizer. Given a transcript, produce a structured summary. \
Do not insert opinions — state the facts. Follow the same language as the session.");

    // 2. Output format
    prompt.push_str("

## Output format

# {Title}

{One sentence description}, meeting duration.

## Attendees

- {Name 1}
- {Name 2}

## TODO

- [ ] **{Owner 1}**: ...
- [ ] **{Owner 2}**: ...

## {Topic 1}

{list down opinions of each attendee}

{conclusion}

## {Topic 2}

...");

    // 3. Rules
    prompt.push_str("

## Rules

- Include a TODO section with action items and owners near the top, right after attendees. If there are no action items, write \"No action items.\"
- Use markdown checkbox syntax: `- [ ] **Owner**: task description` (incomplete) or `- [x] **Owner**: task description` (completed). One item per owner; if ambiguous, assign to the most likely owner; if shared, create separate items per person.
- Cite every key point, decision, action item, or claim with an inline [MM:SS] timestamp from the transcript. Always add a space before the first timestamp: `text [12:45]` not `text[12:45]`. Chain multiple: [12:45][15:20].
- When providing Chinese content, add a space between Chinese characters and English letters or Arabic numerals.");

    // 4. User customizations (from Settings > Pipeline > Prompt)
    let user_extra = user_prompt.trim();
    if !user_extra.is_empty() {
        prompt.push_str("\n\n## Additional instructions\n\n");
        prompt.push_str(user_extra);
    }

    // 5. Session metadata
    let now_local = Local::now();
    prompt.push_str(&format!("\n\nLanguage: {}\nCurrent time: {}",
        ctx.language,
        now_local.format("%A, %Y-%m-%d %H:%M %Z"),
    ));

    prompt
}

/// Format a session's transcript into a rich text block for the LLM.
///
/// Includes meeting title, unique participants, notes, and timestamped
/// speaker-attributed transcript lines.
pub fn format_meeting_transcript(
    transcript: &Value,
    session_info: Option<&SessionInfo>,
    tag_notes: &[(String, String)],
    person_notes: &[(String, String)],
) -> Result<String, String> {
    let segments = transcript
        .get("segments")
        .and_then(|s| s.as_array())
        .ok_or("Transcript has no segments")?;

    if segments.is_empty() {
        return Err("Transcript is empty".to_string());
    }

    let mut output = String::new();
    output.push_str("Meeting info\n");

    // Meeting title, start time, and duration
    if let Some(info) = session_info {
        if let Some(name) = &info.name {
            output.push_str(&format!("Meeting: {}\n", name));
        }
        let started_local: DateTime<Local> = info.created_at.with_timezone(&Local);
        output.push_str(&format!(
            "Started: {}\n",
            started_local.format("%A, %Y-%m-%d %H:%M %Z")
        ));
        if let Some(dur) = info.duration_secs {
            let h = (dur / 3600.0) as u32;
            let m = ((dur % 3600.0) / 60.0) as u32;
            let s = (dur % 60.0) as u32;
            if h > 0 {
                output.push_str(&format!("Duration: {}h {}m {}s\n", h, m, s));
            } else {
                output.push_str(&format!("Duration: {}m {}s\n", m, s));
            }
        }
    }

    // Unique participants: known names first, then unknown speaker IDs
    let mut known = BTreeSet::new();
    let mut unknown = BTreeSet::new();
    for seg in segments {
        let person_name = seg.get("person_name").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
        let speaker_id = seg.get("speaker").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
        if let Some(name) = person_name {
            known.insert(name.to_string());
        } else if let Some(id) = speaker_id {
            unknown.insert(id.to_string());
        }
    }
    if !known.is_empty() || !unknown.is_empty() {
        let mut parts: Vec<String> = known.into_iter().collect();
        for id in unknown {
            parts.push(format!("{} (unknown participant)", id));
        }
        output.push_str(&format!("Participants: {}\n", parts.join(", ")));
    }

    // Session notes
    if let Some(info) = session_info {
        if let Some(notes) = &info.notes {
            if !notes.trim().is_empty() {
                output.push_str("\nSession notes\n");
                output.push_str(&format!("{}\n", notes.trim()));
            }
        }
    }

    // Tag notes
    let non_empty_tag_notes: Vec<_> = tag_notes
        .iter()
        .filter(|(_, notes)| !notes.trim().is_empty())
        .collect();
    if !non_empty_tag_notes.is_empty() {
        output.push_str("\nTag notes\n");
        for (tag_name, notes) in non_empty_tag_notes {
            output.push_str(&format!("\"{}\": {}\n", tag_name, notes.trim()));
        }
    }

    // Participant notes
    let non_empty_person_notes: Vec<_> = person_notes
        .iter()
        .filter(|(_, notes)| !notes.trim().is_empty())
        .collect();
    if !non_empty_person_notes.is_empty() {
        output.push_str("\nParticipant notes\n");
        for (name, notes) in non_empty_person_notes {
            output.push_str(&format!("\"{}\": {}\n", name, notes.trim()));
        }
    }

    // ASR disclaimer
    output.push_str("\nASR disclaimer\n");
    output.push_str("This transcript was generated by automatic speech recognition (ASR). ");
    output.push_str("Names and words may be mis-recognized, especially those marked as low confidence. ");
    output.push_str("If a mis-recognized word sounds similar to a known participant or term (e.g. from the notes above), it likely refers to that person or term — use the correct one in the summary, and on its first occurrence put the original ASR word in parentheses, e.g. `CorrectTerm (original-asr-word)`.\n");

    // Timestamped transcript lines with low-confidence annotations
    output.push_str("\nTranscript\n");
    for seg in segments {
        output.push_str(&format_segment(seg));
    }

    Ok(output)
}

/// Extract TODO items from summary markdown and match person names to known people.
///
/// Parses lines matching `- [ ] ...` or `- [x] ...`, extracts the person name
/// (typically bold at the start), and looks up their person_id.
/// Try to match a name string against known people (case-insensitive prefix match).
fn match_person(name: &str, all_people: &[crate::people::PersonIndexEntry]) -> (Option<String>, Option<String>) {
    let name_lower = name.to_lowercase();
    for p in all_people {
        let p_lower = p.name.to_lowercase();
        if p_lower == name_lower
            || p_lower.starts_with(&name_lower)
            || name_lower.starts_with(&p_lower)
        {
            return (Some(p.name.clone()), Some(p.id.clone()));
        }
    }
    (Some(name.to_string()), None)
}

async fn extract_todos(content: &str, people_manager: &PeopleManager) -> Vec<Value> {
    // Cache all people for name matching
    let all_people = people_manager.list_people().await;

    let mut todos = Vec::new();
    let re_todo = regex::Regex::new(r"- \[([ xX])\] (.+)").unwrap();
    let re_bold = regex::Regex::new(r"^\*\*(.+?)\*\*").unwrap();

    for cap in re_todo.captures_iter(content) {
        let completed = cap[1].trim().len() > 0; // "x" or "X" = completed
        let text = cap[2].trim().to_string();

        // Try to extract person name from bold prefix: **Name** – task text
        let mut task_text = text.clone();

        if let Some(bold_cap) = re_bold.captures(&text) {
            let raw_name = bold_cap[1].trim().to_string();
            // Extract the task portion after the name
            let after_bold = &text[bold_cap.get(0).unwrap().end()..];
            task_text = after_bold.trim_start_matches(&[' ', '–', '—', '-', ':'][..]).trim().to_string();

            // Split on / , & and to handle multi-person TODOs like "Alex/Sam/Jordan"
            let name_parts: Vec<&str> = regex::Regex::new(r"[/,&]|\band\b")
                .unwrap()
                .split(&raw_name)
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .collect();

            if name_parts.len() > 1 {
                // Create a separate TODO entry per person
                for part in &name_parts {
                    let (person_name, person_id) = match_person(part, &all_people);
                    todos.push(json!({
                        "text": task_text,
                        "full_text": text,
                        "completed": completed,
                        "person_name": person_name,
                        "person_id": person_id,
                    }));
                }
                continue;
            }

            // Single person
            let (person_name, person_id) = match_person(&raw_name, &all_people);
            todos.push(json!({
                "text": task_text,
                "full_text": text,
                "completed": completed,
                "person_name": person_name,
                "person_id": person_id,
            }));
        } else {
            // No bold name found
            todos.push(json!({
                "text": task_text,
                "full_text": text,
                "completed": completed,
                "person_name": null,
                "person_id": null,
            }));
        }
    }

    todos
}

/// Run the full summarization pipeline for a session.
///
/// 1. Reads `transcript.json` from the session directory
/// 2. Formats the transcript with meeting context
/// 3. Builds the system prompt with metadata
/// 4. Streams the LLM response, emitting delta events via WebSocket
/// 5. Writes the result to `summary.json`
pub async fn run_summarization(
    session_id: &str,
    session_dir: &Path,
    host: &str,
    api_key: &str,
    model: &str,
    user_prompt: &str,
    session_info: Option<&SessionInfo>,
    tags_manager: &TagsManager,
    people_manager: &PeopleManager,
    session_manager: &SessionManager,
    provider_sort: Option<&str>,
) -> Result<(), String> {
    let summary_revision = crate::storage::revision(&session_dir.join("summary.json"));
    let todos_revision = crate::storage::revision(&session_dir.join("todos.json"));
    let language = session_info
        .map(|s| s.language.as_str())
        .unwrap_or("en");

    // Read and format transcript
    let transcript_path = session_dir.join("transcript.json");
    let transcript_path = transcript_path.to_path_buf();
    let transcript = crate::storage::blocking(move || crate::storage::read_without_words(&transcript_path)).await?;

    // Collect notes from tags and participants
    let session_tags = session_info.map(|s| s.tags.as_slice()).unwrap_or(&[]);
    let tag_notes = collect_tag_notes(tags_manager, session_tags).await;
    let person_ids = extract_person_ids(&transcript);
    let person_notes = collect_person_notes(people_manager, &person_ids).await;

    let meeting_text = format_meeting_transcript(&transcript, session_info, &tag_notes, &person_notes)?;

    // Build prompt
    let ctx = SummarizationContext {
        session_info,
        language,
    };
    let system_prompt = build_system_prompt(user_prompt, &ctx);

    info!("[{}] Generating summary with model {}", session_id, model);

    let client = LlmClient::new(host.to_string(), api_key.to_string(), model.to_string())
        .with_provider_sort(provider_sort.map(|s| s.to_string()));
    let messages = vec![
        json!({"role": "system", "content": system_prompt}),
        json!({"role": "user", "content": format!("Here is the meeting transcript:\n\n{}", meeting_text)}),
    ];

    // Stream the response, emitting deltas via WebSocket
    let stream_start = std::time::Instant::now();
    let stream = client.stream_chat(messages.clone()).await?;
    futures::pin_mut!(stream);

    let mut content = String::new();
    let mut first_chunk = true;
    let mut was_thinking = false;
    let mut usage_value: Option<Value> = None;
    let mut finish_reason: Option<String> = None;
    let mut provider: Option<String> = None;
    while let Some(result) = stream.next().await {
        match result {
            Ok(delta) => {
                // \x01 prefix = thinking/reasoning token (not part of final content)
                let is_thinking = delta.starts_with('\x01');
                if is_thinking {
                    if first_chunk {
                        info!("[{}] Thinking started ({:.1}s)", session_id, stream_start.elapsed().as_secs_f64());
                        first_chunk = false;
                        was_thinking = true;
                        session_manager.emit_summary_progress(session_id, "thinking").await;
                    }
                    let thinking_text = delta.trim_start_matches('\x01');
                    if !thinking_text.is_empty() {
                        session_manager.emit_summary_thinking(session_id, thinking_text);
                    }
                    continue; // Don't include thinking in output
                }

                // \x03 prefix = finish_reason
                if let Some(reason) = delta.strip_prefix('\x03') {
                    finish_reason = Some(reason.to_string());
                    continue;
                }

                // \x02 prefix = usage info
                if let Some(usage_str) = delta.strip_prefix('\x02') {
                    usage_value = serde_json::from_str(usage_str).ok();
                    continue;
                }

                // \x04 prefix = provider info
                if let Some(p) = delta.strip_prefix('\x04') {
                    provider = Some(p.to_string());
                    continue;
                }

                if first_chunk {
                    info!("[{}] Stream started ({:.1}s)", session_id, stream_start.elapsed().as_secs_f64());
                    first_chunk = false;
                } else if was_thinking {
                    info!("[{}] Content started ({:.1}s)", session_id, stream_start.elapsed().as_secs_f64());
                    was_thinking = false;
                }

                content.push_str(&delta);
                session_manager.emit_summary_delta(session_id, &delta);
            }
            Err(e) => {
                warn!("[{}] Summary stream error: {}", session_id, e);
                return Err(e);
            }
        }
    }

    if content.is_empty() {
        return Err("LLM returned empty response".to_string());
    }

    let mut summary = json!({
        "content": content,
        "model": model,
        "messages": messages,
        "generated_at": Utc::now().to_rfc3339(),
        "finish_reason": finish_reason.as_deref().unwrap_or("unknown"),
    });

    if let Some(ref usage) = usage_value {
        let prompt = usage.get("prompt_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        let completion = usage.get("completion_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        let total = usage.get("total_tokens").and_then(|v| v.as_u64()).unwrap_or(prompt + completion);
        let cost = usage.get("cost").and_then(|v| v.as_f64());
        let cost_str = cost.map(|c| format!(", cost ${:.4}", c)).unwrap_or_default();
        let reason_str = finish_reason.as_deref().unwrap_or("unknown");
        let provider_str = provider.as_deref().unwrap_or("unknown");
        info!(
            "[{}] Summary saved (finish_reason: {}, provider: {}) — {} prompt + {} completion = {} tokens{}",
            session_id, reason_str, provider_str, prompt, completion, total, cost_str
        );
        if reason_str == "length" {
            warn!("[{}] Summary may be truncated — model hit max token limit", session_id);
        }
        summary["usage"] = usage.clone();
    } else {
        let reason_str = finish_reason.as_deref().unwrap_or("unknown");
        let provider_str = provider.as_deref().unwrap_or("unknown");
        info!("[{}] Summary saved (finish_reason: {}, provider: {})", session_id, reason_str, provider_str);
        if reason_str == "length" {
            warn!("[{}] Summary may be truncated — model hit max token limit", session_id);
        }
    }

    let summary_path = session_dir.join("summary.json");
    crate::storage::replace_json(&summary_path, summary_revision, &summary)
        .map_err(|e| format!("Failed to write summary: {e}"))?;

    let md_path = session_dir.join("summary.md");
    std::fs::write(&md_path, &content)
        .map_err(|e| format!("Failed to write summary.md: {e}"))?;

    // Extract TODOs and save per-session
    let todos = extract_todos(&content, people_manager).await;
    if !todos.is_empty() {
        let todos_value = json!({"items": todos});
        let todos_path = session_dir.join("todos.json");
        crate::storage::replace_json(&todos_path, todos_revision, &todos_value)
            .map_err(|e| format!("Failed to write todos.json: {e}"))?;
        info!("[{}] Extracted {} TODOs", session_id, todos.len());
    }

    Ok(())
}
