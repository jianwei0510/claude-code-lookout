// 這一行 export 讓這個檔是「模組」，下面的 declare module 才是擴充 'claude-code'，而不是取代它。
/**
 * Lookout 視窗現在的狀態。
 * - unknown：還沒查過 —— 開關列先不畫，免得一閃而過一個錯的狀態
 * - running／stopped：開著／關著
 * - missing：還沒安裝（找不到 install.sh 裝的那支程式）
 */
export type Status = 'unknown' | 'running' | 'stopped' | 'missing'

declare module 'claude-code' {
  interface PluginState {
    lookout: {
      status: Status
      /** 正在打開或關掉中：按鈕先收起來，免得連按兩次。 */
      busy: boolean
    }
  }
}
