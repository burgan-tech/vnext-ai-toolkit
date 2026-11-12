// fixture: task mapping reading the role header by hand and context.Caller (unavailable in IMapping)
public class ChannelRoleMapping : ScriptBase, IMapping
{
    public async Task<ScriptResponse> InputHandler(WorkflowTask task, ScriptContext context)
    {
        var role = GetPropertyValue<string>(context.Headers, "role", "");
        var officer = await context.Caller.HasRoleAsync("officer");
        return new ScriptResponse { Data = new { role, officer } };
    }

    public Task<ScriptResponse> OutputHandler(ScriptContext context) => Task.FromResult(new ScriptResponse());
}
