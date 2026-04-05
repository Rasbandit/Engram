import { useEffect } from 'react'
import { useAuth } from '@clerk/clerk-react'
import { connectChannel, disconnectChannel } from './channel'
import { queryClient } from './query-client'
import { useMe } from './queries'

export function useChannel() {
  const { getToken } = useAuth()
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
