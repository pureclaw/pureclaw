import { useEffect, useState } from 'react'
import type { SessionInfo, TabInfo } from '../types'
import type { ListsSnapshot, StreamClient } from '../types/stream'
import { streamClient } from '../lib/streamClient'

export function useListsStream(client?: StreamClient) {
  const sc = client ?? streamClient()
  const [tabs, setTabs] = useState<TabInfo[]>([])
  const [recentSessions, setRecentSessions] = useState<SessionInfo[]>([])
  const [archivedSessions, setArchivedSessions] = useState<SessionInfo[]>([])

  useEffect(() => {
    const unsub = sc.onLists((snapshot: ListsSnapshot) => {
      setTabs(snapshot.tabs)
      setRecentSessions(snapshot.recentSessions)
      setArchivedSessions(snapshot.archivedSessions)
    })
    return unsub
  }, [sc])

  return { tabs, recentSessions, archivedSessions }
}
