import { useEffect } from 'react'
import { useAuthAdapter } from '../auth/use-auth-adapter'
import { connectChannel, disconnectChannel } from './channel'
import { queryClient } from './query-client'
import { useMe } from './queries'

export function useChannel() {
  const { getToken } = useAuthAdapter()
  const { data: user } = useMe()

  useEffect(() => {
    if (!user) return

    connectChannel({
      userId: user.id,
      getToken: () => getToken(),
      queryClient,
    })

    return () => disconnectChannel()
  }, [user?.id, getToken])
}
