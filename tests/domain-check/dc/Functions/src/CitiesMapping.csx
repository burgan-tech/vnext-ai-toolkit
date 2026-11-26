// fixture mapping: plain copy in, plain copy out — a declarative block can express it (check 23 candidate)
using System.Threading.Tasks;
using BBT.Workflow.Scripting;

public class CitiesMapping : IMapping
{
    public Task<ScriptResponse> InputHandler(WorkflowTask task, ScriptContext context)
    {
        return Task.FromResult(new ScriptResponse { Data = new { country = context.Instance.Data.country } });
    }

    public Task<ScriptResponse> OutputHandler(ScriptContext context)
    {
        return Task.FromResult(new ScriptResponse { Data = new { cities = context.Body.data } });
    }
}
