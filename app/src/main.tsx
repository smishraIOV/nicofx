import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { WagmiProvider } from 'wagmi'
import { config } from './wagmi'
import { WalletProvider } from './wallet'
import { ProtocolProvider } from './useProtocol'
import App from './App'
import './index.css'

const queryClient = new QueryClient()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <WalletProvider>
          <ProtocolProvider>
            <App />
          </ProtocolProvider>
        </WalletProvider>
      </QueryClientProvider>
    </WagmiProvider>
  </StrictMode>,
)
