
[Flags]
public enum Tags {

    Boot,
    Hourly,
    Daily,
    Weekly,
    Monthly,
    OnDemand,

    First = Boot,
    Last = OnDemand,
    Timed = Boot | Hourly | Daily | Weekly | Monthly,
    All = Timed | OnDemand;

    /**
        A lowercase short name
     */
    public string name() {
        switch(this) {
            case Boot: return "boot";
            case Hourly: return "hourly";
            case Daily: return "daily";
            case Weekly: return "weekly";
            case Monthly: return "monthly";
            case OnDemand: return "ondemand";
        }

        assert_not_reached();
    }

    /**
        A lowercase short name
     */
    public string localized_name() {
        switch(this) {
            case Boot: return _("Boot");
            case Hourly: return _("Hourly");
            case Daily: return _("Daily");
            case Weekly: return _("Weekly");
            case Monthly: return _("Monthly");
            case OnDemand: return _("Ondemand");
        }

        assert_not_reached();
    }

    /**
        A single uppercase letter
     */
    public char letter() {
        switch(this) {
            case Boot: return 'B';
            case Hourly: return 'H';
            case Daily: return 'D';
            case Weekly: return 'W';
            case Monthly: return 'M';
            case OnDemand: return 'O';
        }

        assert_not_reached();
    }

    public static Tags? parse(string input) {
        switch(input.strip().down().get(0)) {
            case 'b': return Boot;
            case 'h': return Hourly;
            case 'd': return Daily;
            case 'w': return Weekly;
            case 'm': return Monthly;
            case 'o': return OnDemand;
        }
        return null;
    }

    public static void set_value(ref Tags tags, Tags value, bool setit) {
        if(setit) {
            tags |= value;
        } else {
            tags &= ~ value;
        }
    }

    public TagsIterator iterator() {
        return new TagsIterator(this);
    }
}

public class TagsIterator {
    private Tags value;
    private Tags pos = Tags.First;

    public TagsIterator(Tags value) {
        this.value = value;
    }

    public bool next() {
        for(Tags t = this.pos; t <= Tags.Last; t <<= 1) {
            if(t in this.value) {
                return true;
            }
        }
        return false;
    }

    public Tags? next_value() {
        for(; this.pos <= Tags.Last; this.pos <<= 1) {
            if(this.pos in this.value) {
                Tags copy = this.pos;
                this.pos <<= 1;
                return copy;
            }
        }
        return null;
    }
}
