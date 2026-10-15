// Pure feedback contract shared by the page and synthetic tests.
const ReviewContract = (() => {
  const version = 2;
  const choices = ['A', 'B', 'same', 'unsure'];
  function key(track, start, end) { return `${track}:${start.toFixed(3)}:${end.toFixed(3)}`; }
  function sides(reviewId, windowKey, methods) {
    if (methods.length !== 2 || methods[0].id === methods[1].id) throw new Error('Choose two different methods.');
    let hash = 2166136261;
    for (const c of `${reviewId}:${windowKey}`) hash = Math.imul(hash ^ c.charCodeAt(0), 16777619);
    const ids = methods.map(m => m.id);
    return hash & 1 ? { A: ids[1], B: ids[0] } : { A: ids[0], B: ids[1] };
  }
  function entry({reviewId, track, source, audioHash, start, end, mapping, choice, issues = [], issueSide = 'both', notes = '', revealed = false, sampling = 'custom'}) {
    if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end <= start) throw new Error('Invalid review window.');
    if (choice !== null && !choices.includes(choice)) throw new Error('Invalid preference.');
    if (!mapping.A || !mapping.B || mapping.A === mapping.B) throw new Error('Invalid side mapping.');
    return {version, reviewId, key: key(track, start, end), track, source, audioHash, start, end,
      mapping, choice, sampling: ['opening', 'uniform', 'disagreement', 'custom'].includes(sampling) ? sampling : 'custom', preferredMethod: ['A', 'B'].includes(choice) ? mapping[choice] : null,
      issues: issues.filter(i => ['missed_speech', 'wrong_speaker', 'fragmented_text'].includes(i)),
      issueSide: ['A', 'B', 'both'].includes(issueSide) ? issueSide : 'both', notes: String(notes),
      methodNamesRevealed: Boolean(revealed), updatedAt: new Date().toISOString()};
  }
  function feedback(reviewId, methods, entries) {
    return {version, reviewId, kind: 'listening_preference_not_ground_truth', methods,
      exportedAt: new Date().toISOString(), reviews: Object.values(entries).filter(e => e.reviewId === reviewId)};
  }
  return {version, key, sides, entry, feedback};
})();
if (typeof module !== 'undefined') module.exports = ReviewContract;
