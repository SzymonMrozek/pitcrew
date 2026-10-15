const node = (tag, text, className) => {const result = document.createElement(tag); if (text !== undefined) result.textContent = text; if (className) result.className = className; return result;};

export function queueLabel(entry) {
  return ({waiting: `Waiting · #${entry.position}`, preparing: 'Preparing', merging: 'Validating & merging', merged: 'Merged', blocked: 'Needs attention'})[entry.phase] || entry.phase;
}

export function renderQueue(root, state, token) {
  const fragment = document.createDocumentFragment();
  for (const [title, entries, empty] of [['Current queue', state.pending, 'Queue is empty.'], ['Needs attention', state.attention, 'No blocked merges.'], ['Recently merged', state.recent, 'No recorded merges yet.']]) {
    const section = node('section', undefined, 'queue-section');
    section.append(node('h3', `${title} · ${entries.length}`));
    if (!entries.length) section.append(node('p', empty, 'muted'));
    for (const entry of entries) {
      const card = node('article', undefined, 'queue-card');
      const heading = node('div', undefined, 'queue-card-heading');
      heading.append(node('strong', entry.title || entry.branch), node('span', queueLabel(entry), 'queue-phase'));
      card.append(heading, node('p', `${entry.branch} → ${entry.target}`, 'muted'));
      const date = entry.finishedAt || entry.requestedAt;
      const dateLabel = entry.finishedAt ? 'Merged' : entry.status === 'merged' ? 'Approved' : 'Queued';
      const time = node('time', `${dateLabel} ${new Date(date).toLocaleString()}`); time.dateTime = date;
      card.append(time);
      if (entry.status === 'blocked') card.append(node('pre', entry.summary || 'Inspect the saved approval.', 'queue-summary'));
      const actions = node('p', undefined, 'queue-actions');
      const link = node('a', 'Review & agent output'); link.href = '/?merge=' + encodeURIComponent(entry.id) + (entry.sessionId ? '&review=' + encodeURIComponent(entry.sessionId) : '') + '#' + token;
      actions.append(link, node('code', entry.id)); card.append(actions);
      if (entry.status !== 'merged') {
        const paths = node('details'); paths.append(node('summary', `Changed paths · ${entry.changedPaths?.length ?? 'unknown'}`));
        paths.append(node('pre', entry.changedPaths?.join('\n') || 'Older approval: inspect its review for affected paths.', 'queue-paths'));
        card.append(paths);
        if (entry.snapshotRef) {
          const snapshot = node('details'); snapshot.append(node('summary', 'Pending Git snapshot'));
          snapshot.append(node('p', 'Saved at approval. Inspect it before applying relevant changes; worker corrections can alter the final result.', 'muted'), node('pre', `git show ${entry.snapshotRef}\ngit diff ${entry.snapshotBase} ${entry.snapshotRef} -- <relevant-path>`, 'queue-paths'));
          card.append(snapshot);
        }
      }
      section.append(card);
    }
    fragment.append(section);
  }
  root.replaceChildren(fragment);
}

export function mountQueue(root, token, onError) {
  let loading = false, rendered;
  const refresh = async () => {
    if (loading) return;
    loading = true;
    try {
      const response = await fetch('/api/queue', {headers: {'X-Review-Token': token || ''}});
      const state = await response.json();
      if (!response.ok) throw new Error(state.error || 'Queue unavailable');
      if (state.tool && root.hasAttribute('data-standalone')) {
        document.querySelectorAll('[data-launcher]').forEach(code => {code.textContent = `${state.tool.launcher} ${code.dataset.launcher}`;});
        const brand = document.querySelector('#brand-title'); if (brand) brand.textContent = state.tool.title;
        document.title = `Merge queue · ${state.tool.title} review`;
      }
      const revision = JSON.stringify(state);
      if (revision !== rendered) {renderQueue(root, state, token); rendered = revision;}
      onError(null);
    } catch (error) {onError(error);} finally {loading = false;}
  };
  setInterval(() => {if (document.visibilityState === 'visible' && (root.hasAttribute('data-standalone') || root.closest('dialog')?.open)) void refresh();}, 2000);
  return refresh;
}

const standalone = typeof document === 'undefined' ? null : document.querySelector('[data-standalone]');
if (standalone) {
  const token = location.hash.slice(1) || sessionStorage.getItem('review-token');
  if (token) sessionStorage.setItem('review-token', token);
  const reviewId = new URLSearchParams(location.search).get('review');
  document.querySelector('#queue-review').href = '/' + (reviewId ? '?review=' + encodeURIComponent(reviewId) : '') + '#' + (token || '');
  const refresh = mountQueue(standalone, token, error => {
    const notice = document.querySelector('#queue-error'); notice.hidden = !error; notice.textContent = error?.message || '';
  });
  document.querySelector('#queue-refresh').onclick = refresh;
  void refresh();
}
