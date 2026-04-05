import { Socket, Channel } from 'phoenix'
import type { QueryClient } from '@tanstack/react-query'

let socket: Socket | null = null
let channel: Channel | null = null

interface ConnectOptions {
  userId: number
  getToken: () => Promise<string | null>
  queryClient: QueryClient
}

interface NoteChangedPayload {
  event_type: string
  path: string
  kind: string
}

export async function connectChannel({ userId, getToken, queryClient }: ConnectOptions) {
  disconnectChannel()

  const token = await getToken()

  socket = new Socket('/socket', {
    params: { token: token ?? '' },
  })

  socket.connect()

  channel = socket.channel(`sync:${userId}`)

  channel.on('note_changed', (payload: NoteChangedPayload) => {
    if (payload.kind === 'note') {
      queryClient.invalidateQueries({ queryKey: ['note', payload.path] })
      queryClient.invalidateQueries({ queryKey: ['folders'] })
      queryClient.invalidateQueries({ queryKey: ['folderNotes'] })
      queryClient.invalidateQueries({ queryKey: ['search'] })
    }
  })

  channel
    .join()
    .receive('ok', () => console.log(`Joined sync:${userId}`))
    .receive('error', (resp) => console.error('Channel join failed', resp))
}

export function disconnectChannel() {
  if (channel) {
    channel.leave()
    channel = null
  }
  if (socket) {
    socket.disconnect()
    socket = null
  }
}
