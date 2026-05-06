import type { Agent, Message, CodeSpan } from '../types'

export const mockAgents: Agent[] = [
  { id: 'review', name: 'Review', status: 'needs-input', tokenCount: '14.2k', description: 'Awaiting security decision' },
  { id: 'test-runner', name: 'Test Runner', status: 'needs-input', tokenCount: '8.1k', description: '3 failures — need fix strategy' },
  { id: 'implement', name: 'Implement', status: 'thinking', tokenCount: '38.5k', description: 'Writing session middleware\u2026' },
  { id: 'oauth', name: 'OAuth', status: 'thinking', tokenCount: '22.0k', description: 'Integrating GitHub PKCE flow' },
  { id: 'migration', name: 'Migration', status: 'thinking', tokenCount: '5.3k', description: 'Creating user_credentials table' },
  { id: 'rate-limit', name: 'Rate Limit', status: 'idle', tokenCount: '11.7k', description: 'Waiting on Implement' },
  { id: 'docs', name: 'Docs', status: 'idle', tokenCount: '2.4k' },
  { id: 'plan', name: 'Plan', status: 'completed', tokenCount: '6.8k' },
  { id: 'scaffold', name: 'Scaffold', status: 'completed', tokenCount: '4.1k' },
  { id: 'config', name: 'Config', status: 'completed', tokenCount: '3.2k' },
  { id: 'schema', name: 'Schema', status: 'completed', tokenCount: '5.5k' },
  { id: 'deps', name: 'Deps', status: 'completed', tokenCount: '1.9k' },
  { id: 'lint', name: 'Lint', status: 'completed', tokenCount: '2.0k' },
]

const loginCode: CodeSpan[][] = [
  [{ type: 'kw', text: 'module' }, { type: 'text', text: ' PureClaw.Auth ' }, { type: 'kw', text: 'where' }],
  [{ type: 'text', text: '' }],
  [{ type: 'kw', text: 'import' }, { type: 'text', text: ' PureClaw.Auth.Session (' }, { type: 'fn', text: 'createSession' }, { type: 'text', text: ', SessionToken(..))' }],
  [{ type: 'kw', text: 'import' }, { type: 'text', text: ' PureClaw.Auth.RateLimit (' }, { type: 'fn', text: 'checkRateLimit' }, { type: 'text', text: ', RateLimitResult(..))' }],
  [{ type: 'kw', text: 'import' }, { type: 'text', text: ' Crypto.Argon2 (' }, { type: 'fn', text: 'verifyEncoded' }, { type: 'text', text: ')' }],
  [{ type: 'text', text: '' }],
  [{ type: 'cm', text: '-- | Authenticate a user with email and password' }],
  [{ type: 'fn', text: 'loginHandler' }, { type: 'text', text: ' :: LoginRequest -> AppM LoginResponse' }],
  [{ type: 'fn', text: 'loginHandler' }, { type: 'text', text: ' req = ' }, { type: 'kw', text: 'do' }],
  [{ type: 'text', text: '  ' }, { type: 'cm', text: '-- Check rate limit before any DB work' }],
  [{ type: 'text', text: '  rl <- ' }, { type: 'fn', text: 'checkRateLimit' }, { type: 'text', text: ' (req.clientIP) (req.email)' }],
  [{ type: 'text', text: '  ' }, { type: 'kw', text: 'case' }, { type: 'text', text: ' rl ' }, { type: 'kw', text: 'of' }],
  [{ type: 'text', text: '    RateLimited retryAfter ->' }],
  [{ type: 'text', text: '      ' }, { type: 'fn', text: 'throwError' }, { type: 'text', text: ' $ err429 { errBody = ' }, { type: 'fn', text: 'rateLimitBody' }, { type: 'text', text: ' retryAfter }' }],
  [{ type: 'text', text: '    Allowed -> ' }, { type: 'fn', text: 'pure' }, { type: 'text', text: ' ()' }],
  [{ type: 'text', text: '' }],
  [{ type: 'text', text: '  ' }, { type: 'cm', text: '-- Look up credentials' }],
  [{ type: 'text', text: '  mcred <- ' }, { type: 'fn', text: 'findCredentialsByEmail' }, { type: 'text', text: ' (req.email)' }],
  [{ type: 'text', text: '  ' }, { type: 'kw', text: 'case' }, { type: 'text', text: ' mcred ' }, { type: 'kw', text: 'of' }],
  [{ type: 'text', text: '    Nothing   -> ' }, { type: 'fn', text: 'throwError' }, { type: 'text', text: ' err401' }],
  [{ type: 'text', text: '    Just cred -> ' }, { type: 'kw', text: 'do' }],
  [{ type: 'text', text: '      ' }, { type: 'kw', text: 'let' }, { type: 'text', text: ' valid = ' }, { type: 'fn', text: 'verifyEncoded' }, { type: 'text', text: ' (cred.passwordHash) (req.password)' }],
  [{ type: 'text', text: '      ' }, { type: 'kw', text: 'if' }, { type: 'text', text: ' valid' }],
  [{ type: 'text', text: '        ' }, { type: 'kw', text: 'then' }, { type: 'text', text: ' ' }, { type: 'kw', text: 'do' }],
  [{ type: 'text', text: '          session <- ' }, { type: 'fn', text: 'createSession' }, { type: 'text', text: ' (cred.userId)' }],
  [{ type: 'text', text: '          ' }, { type: 'fn', text: 'pure' }, { type: 'text', text: ' $ LoginSuccess session' }],
  [{ type: 'text', text: '        ' }, { type: 'kw', text: 'else' }, { type: 'text', text: ' ' }, { type: 'fn', text: 'throwError' }, { type: 'text', text: ' err401' }],
]

export const mockMessages: Message[] = [
  {
    id: 'msg-1',
    agentName: 'Plan',
    agentStatus: 'completed',
    timestamp: '00:00:34',
    blocks: [
      { text: 'Analyzed the existing codebase. The project uses Servant for routing and PostgreSQL via Hasql. No existing auth module. Architecture:' },
      {
        orderedItems: [
          'Credential storage — Argon2id hashing, separate user_credentials table',
          'Session layer — JWT access tokens (15min) + opaque refresh tokens in Redis (30 days)',
          'OAuth2 — Account linking via email match, PKCE for Google and GitHub',
          'Rate limiting — Token bucket per IP + per account, Redis-backed',
        ],
      },
      { text: 'Handing off to Implement. Files: Auth.hs, Auth/Session.hs, Auth/OAuth.hs, Auth/RateLimit.hs, migration.' },
    ],
  },
  {
    id: 'msg-2',
    agentName: 'Implement',
    agentStatus: 'thinking',
    timestamp: '00:02:17',
    isGenerating: true,
    blocks: [
      { text: 'Core auth module done. Login handler with rate limiting and Argon2id verification:' },
      { codeBlock: loginCode },
      { text: 'Working on Auth/Session.hs next — JWT signing and refresh token rotation.' },
    ],
  },
  {
    id: 'msg-3',
    agentName: 'Review',
    agentStatus: 'needs-input',
    timestamp: '00:03:45',
    blocks: [
      { text: 'Reviewed Auth.hs against the plan. Rate limiting and Argon2id usage are correct. Found two issues and one security concern that needs your input.' },
    ],
  },
  {
    id: 'msg-4',
    agentName: 'Review',
    agentStatus: 'needs-input',
    timestamp: '00:03:48',
    blocks: [
      { text: 'The login handler returns err401 for both "user not found" and "wrong password" — good, prevents email enumeration. But there\'s a timing side-channel: the Nothing branch returns immediately while Just runs Argon2id. An attacker can distinguish valid emails by measuring response time.' },
      { text: 'Two decisions needed:' },
      {
        orderedItems: [
          'Add a dummy Argon2id verification in the Nothing branch to equalize timing? Adds ~200ms to failed lookups but closes the side-channel completely.',
          'The plan specifies JWT access tokens (15min). For a user-facing app, this means re-auth every 15 minutes if refresh fails. Increase to 1 hour, or keep 15min and prioritize the silent refresh endpoint?',
        ],
      },
    ],
  },
]

export const mockTaskTitle = 'User Authentication System'
export const mockSelectedAgentId = 'review'

export const mockStats = {
  tokensUsed: 123700,
  tokensTotal: 200000,
  budgetUsed: 6.58,
  budgetTotal: 15.0,
  elapsed: '00:03:48',
  active: 3,
  waiting: 2,
  idle: 1,
  done: 6,
}
