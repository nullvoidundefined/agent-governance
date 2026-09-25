import bcrypt from "bcrypt";

export async function hashPassword(passwordValue: string): Promise<string> {
    const salt = await bcrypt.genSalt(12);
    return bcrypt.hash(passwordValue, salt);
}
