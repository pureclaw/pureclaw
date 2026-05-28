import { useState } from 'react'

const INDENT_PX = 16

interface JsonValueProps {
  value: unknown
  indent: number
  trailing: boolean
  keyPrefix: string | null
}

export function JsonTree({ value }: { value: unknown }) {
  return (
    <div className="json-tree" data-testid="formatted-json-body">
      <JsonValue value={value} indent={0} trailing={false} keyPrefix={null} />
    </div>
  )
}

function JsonValue({ value, indent, trailing, keyPrefix }: JsonValueProps) {
  if (value === null) {
    return <PrimitiveRow indent={indent} keyPrefix={keyPrefix} trailing={trailing} className="json-null" text="null" />
  }
  const t = typeof value
  if (t === 'string') {
    return <StringRow value={value as string} indent={indent} trailing={trailing} keyPrefix={keyPrefix} />
  }
  if (t === 'number' || t === 'boolean') {
    return (
      <PrimitiveRow
        indent={indent}
        keyPrefix={keyPrefix}
        trailing={trailing}
        className={t === 'number' ? 'json-number' : 'json-boolean'}
        text={String(value)}
      />
    )
  }
  if (Array.isArray(value)) {
    return <ArrayNode value={value} indent={indent} trailing={trailing} keyPrefix={keyPrefix} />
  }
  if (t === 'object') {
    return (
      <ObjectNode
        value={value as Record<string, unknown>}
        indent={indent}
        trailing={trailing}
        keyPrefix={keyPrefix}
      />
    )
  }
  return (
    <PrimitiveRow
      indent={indent}
      keyPrefix={keyPrefix}
      trailing={trailing}
      className="json-string"
      text={String(value)}
    />
  )
}

function KeyPrefix({ name }: { name: string }) {
  return (
    <>
      <span className="json-key">"{name}"</span>
      <span className="json-punct">: </span>
    </>
  )
}

function PrimitiveRow({
  indent,
  keyPrefix,
  trailing,
  className,
  text,
}: {
  indent: number
  keyPrefix: string | null
  trailing: boolean
  className: string
  text: string
}) {
  return (
    <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
      {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
      <span className={className}>{text}</span>
      {trailing && <span className="json-punct">,</span>}
    </div>
  )
}

function StringRow({ value, indent, trailing, keyPrefix }: { value: string; indent: number; trailing: boolean; keyPrefix: string | null }) {
  const multiline = value.includes('\n')
  if (!multiline) {
    return (
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
        <span className="json-string">"{value}"</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    )
  }
  // Multi-line: key + opening quote on one row, body in a <pre> at next indent,
  // closing quote on its own row at the current indent.
  return (
    <>
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
        <span className="json-string">"</span>
      </div>
      <pre className="json-string-block" style={{ marginLeft: (indent + 1) * INDENT_PX }}>{value}</pre>
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <span className="json-string">"</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    </>
  )
}

function Toggle({ expanded, onToggle }: { expanded: boolean; onToggle: () => void }) {
  return (
    <button
      type="button"
      className="json-toggle"
      aria-label={expanded ? 'Collapse' : 'Expand'}
      onClick={onToggle}
    >
      {expanded ? '▼' : '▶'}
    </button>
  )
}

function ObjectNode({
  value,
  indent,
  trailing,
  keyPrefix,
}: {
  value: Record<string, unknown>
  indent: number
  trailing: boolean
  keyPrefix: string | null
}) {
  const [expanded, setExpanded] = useState(true)
  const entries = Object.entries(value)

  if (entries.length === 0) {
    return (
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
        <span className="json-punct">{'{}'}</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    )
  }

  const opening = (
    <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
      <Toggle expanded={expanded} onToggle={() => setExpanded(!expanded)} />
      {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
      <span className="json-punct">{'{'}</span>
      {!expanded && (
        <>
          <span className="json-collapsed-summary">
            {' '}{entries.length} {entries.length === 1 ? 'key' : 'keys'}{' '}
          </span>
          <span className="json-punct">{'}'}</span>
          {trailing && <span className="json-punct">,</span>}
        </>
      )}
    </div>
  )

  if (!expanded) return opening

  return (
    <>
      {opening}
      {entries.map(([k, v], i) => (
        <JsonValue
          key={k}
          value={v}
          indent={indent + 1}
          trailing={i < entries.length - 1}
          keyPrefix={k}
        />
      ))}
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <span className="json-punct">{'}'}</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    </>
  )
}

function ArrayNode({
  value,
  indent,
  trailing,
  keyPrefix,
}: {
  value: unknown[]
  indent: number
  trailing: boolean
  keyPrefix: string | null
}) {
  const [expanded, setExpanded] = useState(true)

  if (value.length === 0) {
    return (
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
        <span className="json-punct">{'[]'}</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    )
  }

  const opening = (
    <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
      <Toggle expanded={expanded} onToggle={() => setExpanded(!expanded)} />
      {keyPrefix !== null && <KeyPrefix name={keyPrefix} />}
      <span className="json-punct">{'['}</span>
      {!expanded && (
        <>
          <span className="json-collapsed-summary">
            {' '}{value.length} {value.length === 1 ? 'item' : 'items'}{' '}
          </span>
          <span className="json-punct">{']'}</span>
          {trailing && <span className="json-punct">,</span>}
        </>
      )}
    </div>
  )

  if (!expanded) return opening

  return (
    <>
      {opening}
      {value.map((v, i) => (
        <JsonValue
          key={i}
          value={v}
          indent={indent + 1}
          trailing={i < value.length - 1}
          keyPrefix={null}
        />
      ))}
      <div className="json-row" style={{ paddingLeft: indent * INDENT_PX }}>
        <span className="json-punct">{']'}</span>
        {trailing && <span className="json-punct">,</span>}
      </div>
    </>
  )
}
