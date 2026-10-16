//! dwell 规则：Swift `DwellPolicy.swift` 的移植。
//!
//! 「这张卡能活多久」是一张表——`resolve` 在卡片上屏时按它的字段与设置
//! 算一次（脚本回填改写字段后再算一次）。状态机只*应用*这张表。
//!
//! | urgency  | actions | budget              | auto-close | holds | ages out        |
//! |----------|---------|---------------------|------------|-------|-----------------|
//! | critical | -       | 无（阻塞）          | 无         | 无    | 5 分钟，之后 5 分钟倒计时 |
//! | 其他     | 有      | timeout ?? dwell    | 无         | 有    | 无              |
//! | 其他     | 无      | timeout ?? dwell    | 10 秒      | 无    | 无              |

use std::time::Duration;

use crate::model::Urgency;

/// `DwellPolicy` 由这些时长构建（Swift `DwellTiming`）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DwellTiming {
    /// 发送方 timeout 缺席时的兜底：普通卡片活多久。
    pub dwell: Duration,
    /// 没人看的动作 hold 何时释放。
    pub action_hold_idle: Duration,
    /// 没人碰的阻塞卡片何时降级。
    pub critical_idle: Duration,
    /// 降级（「稍后处理」）后运行的预算。
    pub critical_snooze: Duration,
    /// 展开态信息卡无人接招时的自动收起。
    pub auto_close: Duration,
}

impl Default for DwellTiming {
    fn default() -> Self {
        Self {
            dwell: Duration::from_secs(5),
            action_hold_idle: Duration::from_secs(300),
            critical_idle: Duration::from_secs(300),
            critical_snooze: Duration::from_secs(300),
            auto_close: Duration::from_secs(10),
        }
    }
}

/// 一张活卡能活多久，作为一个值。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DwellPolicy {
    /// 自退倒计时；`None` = 阻塞（critical），永不自消失。
    pub budget: Option<Duration>,
    /// 无人接招的信息卡自动收起。
    pub auto_close_after: Option<Duration>,
    /// 未回应的动作挂起倒计时直到 hold 老去。
    pub hold_for_actions: bool,
    /// 阻塞卡片占屏这么久后降级（`None` = ageOutCriticals 关）。
    pub age_out_after: Option<Duration>,
    /// 降级后运行的预算。
    pub age_out_budget: Duration,
    /// 动作 hold 持续多久。
    pub hold_release_after: Option<Duration>,
}

impl DwellPolicy {
    /// 「这张卡能活多久」的唯一答案，取自卡片字段与上屏时的设置。
    pub fn resolve(
        urgency: Urgency,
        has_actions: bool,
        sender_timeout: Option<f64>,
        dwell_seconds: f64,
        age_out_criticals: bool,
        timing: DwellTiming,
    ) -> Self {
        if urgency == Urgency::Critical {
            return Self {
                budget: None,
                // critical 的出口是动作、老化或手动关闭。
                auto_close_after: None,
                hold_for_actions: false,
                age_out_after: age_out_criticals.then_some(timing.critical_idle),
                age_out_budget: timing.critical_snooze,
                hold_release_after: None,
            };
        }
        Self {
            // 零预算会把消息困死在屏上；底限就是表里的 dwell。
            budget: Some(
                Duration::try_from_secs_f64(sender_timeout.unwrap_or(dwell_seconds).max(0.1))
                    .unwrap_or(Duration::from_millis(100))
                    .max(Duration::from_millis(100)),
            ),
            auto_close_after: (!has_actions).then_some(timing.auto_close),
            hold_for_actions: has_actions,
            age_out_after: None,
            age_out_budget: timing.critical_snooze,
            hold_release_after: has_actions.then_some(timing.action_hold_idle),
        }
    }

    /// 「稍后处理」（或自行老化）之后的同一张卡：不再阻塞，跑在 snooze
    /// 预算上。这是一个*迁移*而非字段编辑：原本阻塞的卡现在有了倒计时，
    /// 它的动作于是挂住这个倒计时（「发送方还在等」），释放定时器也必须
    /// 跟着武装起来。
    pub fn demoted_to_snooze(self, has_actions: bool, timing: DwellTiming) -> Self {
        Self {
            budget: Some(self.age_out_budget),
            auto_close_after: None,
            hold_for_actions: has_actions,
            age_out_after: None,
            age_out_budget: self.age_out_budget,
            hold_release_after: has_actions.then_some(timing.action_hold_idle),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn timing() -> DwellTiming {
        DwellTiming::default()
    }

    #[test]
    fn table_matches_swift() {
        let t = timing();
        // critical：阻塞、不自动收起、5 分钟老化后 5 分钟倒计时。
        let policy = DwellPolicy::resolve(Urgency::Critical, true, Some(30.0), 5.0, true, t);
        assert_eq!(policy.budget, None);
        assert_eq!(policy.auto_close_after, None);
        assert_eq!(policy.age_out_after, Some(Duration::from_secs(300)));
        assert_eq!(policy.age_out_budget, Duration::from_secs(300));
        assert!(!policy.hold_for_actions);
        // ageOutCriticals 关：永不老化。
        let policy = DwellPolicy::resolve(Urgency::Critical, false, None, 5.0, false, t);
        assert_eq!(policy.age_out_after, None);

        // 普通 + 动作：timeout ?? dwell，挂起但 10 秒不自动收起。
        let policy = DwellPolicy::resolve(Urgency::Normal, true, Some(20.0), 5.0, true, t);
        assert_eq!(policy.budget, Some(Duration::from_secs(20)));
        assert_eq!(policy.auto_close_after, None);
        assert!(policy.hold_for_actions);
        assert_eq!(policy.hold_release_after, Some(Duration::from_secs(300)));

        // 普通 + 无动作：dwell 兜底 + 10 秒自动收起。
        let policy = DwellPolicy::resolve(Urgency::Normal, false, None, 7.0, true, t);
        assert_eq!(policy.budget, Some(Duration::from_secs(7)));
        assert_eq!(policy.auto_close_after, Some(Duration::from_secs(10)));

        // resolve 层的地板（Swift `.max(0.1, …)`）：万一上游漏钳，
        // 零预算也不会把消息困死。钳制本体在 validator（norm_timeout 测试）。
        let policy = DwellPolicy::resolve(Urgency::Normal, false, Some(0.0), 5.0, true, t);
        assert_eq!(policy.budget, Some(Duration::from_millis(100)));
        let policy = DwellPolicy::resolve(Urgency::Normal, false, Some(1.0), 5.0, true, t);
        assert_eq!(policy.budget, Some(Duration::from_secs(1)));
    }

    #[test]
    fn demote_gains_countdown_and_hold() {
        let t = timing();
        let policy = DwellPolicy::resolve(Urgency::Critical, true, None, 5.0, true, t);
        let demoted = policy.demoted_to_snooze(true, t);
        assert_eq!(demoted.budget, Some(Duration::from_secs(300)));
        assert!(demoted.hold_for_actions);
        assert_eq!(demoted.hold_release_after, Some(Duration::from_secs(300)));
        // critical 不再霸屏，但不像信息卡一样开始过期。
        assert_eq!(demoted.auto_close_after, None);
        // 无动作的降级卡没有 hold。
        let demoted = policy.demoted_to_snooze(false, t);
        assert!(!demoted.hold_for_actions);
    }
}
