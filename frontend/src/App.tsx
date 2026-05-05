import { useState } from 'react'
import { TopBar } from './components/TopBar'
import { Sidebar } from './components/Sidebar'
import { ChatArea } from './components/ChatArea'
import { BottomBar } from './components/BottomBar'
import { mockAgents, mockMessages, mockTaskTitle, mockSelectedAgentId, mockStats } from './data/mockData'

export default function App() {
  const [selectedAgentId, setSelectedAgentId] = useState(mockSelectedAgentId)
  const selectedAgent = mockAgents.find((a) => a.id === selectedAgentId) ?? mockAgents[0]!

  return (
    <>
      <TopBar taskTitle={mockTaskTitle} />
      <div className="flex flex-1 min-h-0">
        <Sidebar agents={mockAgents} selectedId={selectedAgentId} onSelectAgent={setSelectedAgentId} />
        <ChatArea selectedAgent={selectedAgent} messages={mockMessages} />
      </div>
      <BottomBar {...mockStats} />
    </>
  )
}
