// fixture: automatic rule reading context.Caller without an IsAvailable guard (domain-check check 21)
public class IsApproverRule : ScriptBase, IConditionMapping
{
    public async Task<bool> Handler(ScriptContext context) =>
        await context.Caller.HasRoleAsync("morph-idm.approver");
}
