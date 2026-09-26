import { Fragment } from 'react';

// Renders the small markdown subset the model uses (**bold**, "- " or
// "1. " lists, line breaks) as React elements. Model output is never
// parsed as HTML, so it can't inject markup.
function inline(text) {
  return text.split(/\*\*(.+?)\*\*/g).map((part, i) =>
    i % 2 === 1 ? <strong key={i}>{part}</strong> : <Fragment key={i}>{part}</Fragment>,
  );
}

export default function FormattedReply({ text }) {
  const blocks = [];
  for (const line of text.split('\n')) {
    const bullet = line.match(/^\s*[-*•]\s+(.*)$/);
    const numbered = line.match(/^\s*\d+[.)]\s+(.*)$/);
    const item = bullet ?? numbered;
    const listType = bullet ? 'ul' : 'ol';
    const last = blocks[blocks.length - 1];

    if (item) {
      if (last?.type === listType) last.items.push(item[1]);
      else blocks.push({ type: listType, items: [item[1]] });
    } else if (line.trim() === '') {
      blocks.push({ type: 'break' });
    } else if (last?.type === 'p') {
      last.lines.push(line);
    } else {
      blocks.push({ type: 'p', lines: [line] });
    }
  }

  return blocks.map((block, i) => {
    if (block.type === 'break') return null;
    if (block.type === 'p') {
      return (
        <p key={i}>
          {block.lines.map((line, j) => (
            <Fragment key={j}>
              {j > 0 && <br />}
              {inline(line)}
            </Fragment>
          ))}
        </p>
      );
    }
    const List = block.type;
    return (
      <List key={i}>
        {block.items.map((itemText, j) => (
          <li key={j}>{inline(itemText)}</li>
        ))}
      </List>
    );
  });
}
