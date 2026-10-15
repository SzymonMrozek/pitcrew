import {Marked} from './vendor/marked.mjs';

const escape = text => text.replace(/[&<>"']/g, character => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[character]));
const parser = new Marked({renderer: {
  // Repository text is untrusted: display raw HTML and never load embedded images.
  html({text}) {return escape(text);},
  link({href, tokens}) {
    const label = this.parser.parseInline(tokens);
    if (!/^(https?:\/\/|mailto:)/i.test(href)) return label;
    return `<a href="${escape(href)}" target="_blank" rel="noopener noreferrer">${label}</a>`;
  },
  image({text}) {return `<span class="muted">[Image: ${escape(text)}]</span>`;},
}});

export function renderMarkdown(text) {return parser.parse(text);}
export function isMarkdown(path) {return /\.(md|markdown|mdown)$/i.test(path);}
