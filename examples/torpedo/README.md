flowchart LR
  subgraph App["Screen redraw\npacing delays\nevent log"]
    UI["Screen redraw\npacing delays\nevent log"]
    Loop["Turn loop"]
    RedWrap["Red wrapper\nTorpedolib()"]
    BlueWrap["Blue wrapper\nTorpedolib()"]
  end

  subgraph RedCtx["torpedolib ctxRed"]
    RedReq["Request providers\nInitializeCaptainRequest\nAutoPlaceFleetRequest\nGetNextShotRequest\nObserveShotOutcomeRequest\nGetPublicBoardRequest"]
    RedState["Private captain state\nboard\nAI memory\nreplay log"]
    RedEvt["Event brokers\nCaptainRemark\nShotResolved\nBoardChanged\nMatchEnded"]
  end

  subgraph BlueCtx["torpedolib ctxBlue"]
    BlueReq["Request providers\nInitializeCaptainRequest\nAutoPlaceFleetRequest\nReceiveShotRequest\nGetPublicBoardRequest"]
    BlueState["Private captain state\nboard\nAI memory\nreplay log"]
    BlueEvt["Event brokers\nCaptainRemark\nShotResolved\nBoardChanged\nMatchEnded"]
  end

  Loop -->|s28| RedWrap
  Loop -->|s29| BlueWrap

  Loop -->|s30| RedWrap
  RedWrap --> RedReq
  RedReq --> RedState
  RedState -->|s31| Loop

  Loop -->|s32| BlueWrap
  BlueWrap --> BlueReq
  BlueReq --> BlueState
  BlueState -->|s31| Loop

  Loop -->|s33| RedWrap
  RedWrap --> RedReq
  RedReq --> RedState

  Loop -->|s34| RedWrap
  Loop -->|s34| BlueWrap
  RedWrap --> RedReq
  BlueWrap --> BlueReq
  RedReq -->|s35| UI
  BlueReq -->|s35| UI

  RedState -.-> RedEvt
  BlueState -.-> BlueEvt
  RedEvt -.->|s36| RedWrap
  BlueEvt -.->|s36| BlueWrap
  RedWrap -.-> UI
  BlueWrap -.-> UI