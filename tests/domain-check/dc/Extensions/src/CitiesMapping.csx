// fixture mapping: a safe-access helper and a log line only — soft reasons, check 23 `incele`
using System.Threading.Tasks;
using BBT.Workflow.Scripting;

public class CitiesMapping : ScriptBase, IMapping
{
    public Task<ScriptResponse> InputHandler(WorkflowTask task, ScriptContext context)
    {
        return Task.FromResult(new ScriptResponse());
    }

    public Task<ScriptResponse> OutputHandler(ScriptContext context)
    {
        LogInformation("cities read");
        var cities = HasProperty(context.Body, "data") ? context.Body.data : null;
        return Task.FromResult(new ScriptResponse { Data = new { cities } });
    }
}
