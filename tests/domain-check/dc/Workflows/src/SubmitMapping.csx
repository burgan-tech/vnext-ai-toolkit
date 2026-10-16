// fixture mapping: a secret read, a payload serialized into a log call, a filter path
public class SubmitMapping
{
    public void Handle(dynamic context, dynamic logger)
    {
        var key = GetSecret("store", "bundle", "api-key");
        logger.LogInformation("body {b}", JsonSerializer.Serialize(context.Instance.Data));
        var filter = "attributes.nationalId";
    }
}
