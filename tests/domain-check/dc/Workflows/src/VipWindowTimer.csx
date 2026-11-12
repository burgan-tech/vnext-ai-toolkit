// fixture: guarded timer — must NOT be reported
public class VipWindowTimer : ScriptBase, ITimerMapping
{
    public async Task<TimerSchedule> Handler(ScriptContext context)
    {
        var vip = context.Caller.IsAvailable && await context.Caller.HasRoleAsync("vip");
        return TimerSchedule.FromDuration(vip ? TimeSpan.FromHours(48) : TimeSpan.FromHours(24));
    }
}
