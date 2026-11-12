// fixture mapping: a secret read, a payload serialized into a log call, a filter path, a FanOut:ItemFailed match
public class SubmitMapping
{
    public void Handle(dynamic context, dynamic logger)
    {
        var key = GetSecret("store", "bundle", "api-key");
        logger.LogInformation("body {b}", JsonSerializer.Serialize(context.Instance.Data));
        var filter = "attributes.nationalId";
        var ignoredRefusal = item.ErrorCode == "FanOut:ItemFailed"; // pre-0.0.104 way to spot an ignored item
    }
}
