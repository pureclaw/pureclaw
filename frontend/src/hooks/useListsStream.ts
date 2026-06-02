import { useEffect, useState } from 'react'
import type { SessionInfo, TabInfo } from '../types'
import type { ListsSnapshot, StreamClient } from '../types/stream'
import { streamClient } from '../lib/streamClient'
import { mapTabInfo } from './useApi'

export function useListsStream(client?: StreamClient) {
  const sc = client ?? streamClient()
  const [tabs, setTabs] = useState<TabInfo[]>([])
  const [recentSessions, setRecentSessions] = useState<SessionInfo[]>([])
  const [archivedSessions, setArchivedSessions] = useState<SessionInfo[]>([])

  useEffect(() => {
    const unsub = sc.onLists((snapshot: ListsSnapshot) => {
      // The WS `lists` frame carries tabs as raw backend JSON (the new health
      // fields are snake_case). Normalize them to the camelCase TabInfo shape
      // the UI renders, mirroring the REST `/api/tabs` boundary in useTabs.
      // SAFETY: snapshot.tabs is external wire data; mapTabInfo reads only the
      // wire keys and tolerates Phase-1 objects missing the new fields.
      setTabs(snapshot.tabs.map((t) => mapTabInfo(t as unknown as Parameters<typeof mapTabInfo>[0])))
      setRecentSessions(snapshot.recentSessions)
      setArchivedSessions(snapshot.archivedSessions)
    })
    return unsub
  }, [sc])

  return { tabs, recentSessions, archivedSessions }
}
